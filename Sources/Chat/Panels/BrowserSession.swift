#if os(macOS)
import AppKit
#endif
import WebKit

/// One embedded web page in the thread panel (the Browser tab): its page, back/forward history
/// and load state. `ThreadPanelState.openWeb(_:)` creates it lazily and loads links into it, so
/// every link opened from the thread pushes onto the same history.
///
/// On macOS/iOS 26 it drives a SwiftUI `WebPage` (shown with `WebView`); before (macOS 15, iOS 18–25) a `WKWebView`
/// whose state is mirrored through KVO (shown with `LegacyWebView`). Views only read the
/// properties below and call the actions, whichever engine runs.
@Observable @MainActor
final class BrowserSession {
    /// What the page failed to load with (shown over the page); cleared by the next load.
    private(set) var error: String?
    /// The URL last asked for, shown until the page reports its own.
    private(set) var requestedURL: URL

    /// `WebPage` on macOS 26, `WKWebView` before (stored properties can't be availability-gated).
    @ObservationIgnored private let engine: AnyObject
    @ObservationIgnored private var legacyDelegate: LegacyDelegate?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// Follows the current navigation's events (macOS/iOS 26); replaced by the next navigation.
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    /// KVO mirror of the `WKWebView` state (macOS 15 only).
    private var snapshot = Snapshot()

    private struct Snapshot {
        var url: URL?
        var title = ""
        var isLoading = false
        var progress = 0.0
        var canGoBack = false
        var canGoForward = false
        var secure = false
    }

    /// Mobile/desktop sites look for "Safari" in the user agent; without it some serve a degraded page.
    private static let applicationName = "Version/26.0 Safari/605.1.15"

    init(url: URL) {
        requestedURL = url
        let box = WeakBox()
        if #available(macOS 26, iOS 26, *) {
            var config = WebPage.Configuration()
            config.applicationNameForUserAgent = Self.applicationName
            engine = WebPage(configuration: config, navigationDecider: Decider(box: box))
        } else {
            let config = WKWebViewConfiguration()
            config.applicationNameForUserAgent = Self.applicationName
            let webView = WKWebView(frame: .zero, configuration: config)
            webView.allowsBackForwardNavigationGestures = true
            #if os(macOS)
            webView.allowsMagnification = true
            #endif
            engine = webView
        }
        box.session = self
        if let webView = engine as? WKWebView { attach(webView, box: box) }
        load(url)
    }

    // MARK: State

    @available(macOS 26, iOS 26, *)
    var page: WebPage { engine as! WebPage }
    /// The macOS 15 engine; nil on macOS 26.
    var webView: WKWebView? { engine as? WKWebView }

    var url: URL? {
        if #available(macOS 26, iOS 26, *) { return page.url ?? requestedURL }
        return snapshot.url ?? requestedURL
    }

    var title: String {
        if #available(macOS 26, iOS 26, *) { return page.title }
        return snapshot.title
    }

    var isLoading: Bool {
        if #available(macOS 26, iOS 26, *) { return page.isLoading }
        return snapshot.isLoading
    }

    /// 0…1
    var progress: Double {
        if #available(macOS 26, iOS 26, *) { return page.estimatedProgress }
        return snapshot.progress
    }

    var canGoBack: Bool {
        if #available(macOS 26, iOS 26, *) { return !page.backForwardList.backList.isEmpty }
        return snapshot.canGoBack
    }

    var canGoForward: Bool {
        if #available(macOS 26, iOS 26, *) { return !page.backForwardList.forwardList.isEmpty }
        return snapshot.canGoForward
    }

    /// https with no insecure subresources (Safari's lock).
    var isSecure: Bool {
        guard url?.scheme?.lowercased() == "https" else { return false }
        if #available(macOS 26, iOS 26, *) { return page.hasOnlySecureContent }
        return snapshot.secure
    }

    /// "example.com" without "www.".
    var host: String {
        guard let host = url?.host(), !host.isEmpty else { return url?.absoluteString ?? "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: Actions

    func load(_ url: URL) {
        error = nil
        requestedURL = url
        if #available(macOS 26, iOS 26, *) {
            track(page.load(URLRequest(url: url)))
        } else {
            webView?.load(URLRequest(url: url))
        }
    }

    func goBack() {
        error = nil
        if #available(macOS 26, iOS 26, *) {
            if let item = page.backForwardList.backList.last { track(page.load(item)) }
        } else {
            webView?.goBack()
        }
    }

    func goForward() {
        error = nil
        if #available(macOS 26, iOS 26, *) {
            if let item = page.backForwardList.forwardList.first { track(page.load(item)) }
        } else {
            webView?.goForward()
        }
    }

    func reload() {
        error = nil
        if #available(macOS 26, iOS 26, *) {
            if page.url == nil { load(requestedURL) } else { track(page.reload()) }
        } else if let webView {
            if webView.url == nil { load(requestedURL) } else { webView.reload() }
        }
    }

    func stop() {
        if #available(macOS 26, iOS 26, *) { page.stopLoading() } else { webView?.stopLoading() }
    }

    /// The page is going away: stops loading and stops following the navigation.
    func close() {
        navigationTask?.cancel()
        navigationTask = nil
        stop()
    }

    /// The page in the user's default browser.
    func openInDefaultBrowser() {
        if let url { Platform.openExternally(url) }
    }

    func copyLink() {
        guard let url else { return }
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .URL)
        pasteboard.setString(url.absoluteString, forType: .string)
        #else
        Platform.copy(url.absoluteString)
        #endif
    }

    // MARK: Navigation policy (both engines)

    /// Links opened from inside the page: ⌘-click and non-web schemes (mailto:, …) go to the
    /// system; target=_blank / window.open load here instead of a new window.
    fileprivate func decide(url: URL?, isLink: Bool, newWindow: Bool, commandKey: Bool) -> Bool {
        guard let url else { return true }
        let scheme = url.scheme?.lowercased() ?? ""
        if isLink && commandKey || !["http", "https", "about", "blob", "data"].contains(scheme) {
            Platform.openExternally(url)
            return false
        }
        if newWindow {
            load(url)
            return false
        }
        return true
    }

    /// Responses WebKit can't show (downloads, archives) open in the default browser instead.
    fileprivate func decide(response: URLResponse, canShow: Bool, isMainFrame: Bool) -> Bool {
        guard !canShow, isMainFrame, let url = response.url else { return true }
        Platform.openExternally(url)
        return false
    }

    fileprivate func fail(_ error: Error) {
        let ns = error as NSError
        // Superseded loads and policy cancels (⌘-click, downloads handed off) aren't failures.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        self.error = ns.localizedDescription
    }

    // MARK: Engines

    @available(macOS 26, iOS 26, *)
    private func track(_ events: some AsyncSequence<WebPage.NavigationEvent, any Error>) {
        navigationTask?.cancel()
        navigationTask = Task { [weak self] in
            do {
                for try await _ in events {}
            } catch is CancellationError {
            } catch let WebPage.NavigationError.failedProvisionalNavigation(underlying) {
                if !Task.isCancelled { self?.fail(underlying) }
            } catch WebPage.NavigationError.pageClosed {
            } catch {
                if !Task.isCancelled { self?.fail(error) }
            }
        }
    }

    @available(macOS 26, iOS 26, *)
    private struct Decider: WebPage.NavigationDeciding {
        let box: WeakBox

        func decidePolicy(for action: WebPage.NavigationAction,
                          preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
            #if os(macOS)
            let command = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            #else
            let command = false // ⌘-click is a Mac affordance
            #endif
            let allow = box.session?.decide(url: action.request.url, isLink: action.navigationType == .linkActivated,
                                            newWindow: action.target == nil, commandKey: command) ?? true
            return allow ? .allow : .cancel
        }

        func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
            // NavigationResponse doesn't say which frame; only top-level documents reach here unshowable.
            let allow = box.session?.decide(response: response.response, canShow: response.canShowMimeType,
                                            isMainFrame: true) ?? true
            return allow ? .allow : .cancel
        }
    }

    private func attach(_ webView: WKWebView, box: WeakBox) {
        let delegate = LegacyDelegate(box: box)
        legacyDelegate = delegate
        webView.navigationDelegate = delegate
        func observe<T>(_ keyPath: KeyPath<WKWebView, T>) -> NSKeyValueObservation {
            webView.observe(keyPath, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.sync(webView) }
            }
        }
        observations = [observe(\.url), observe(\.title), observe(\.isLoading), observe(\.estimatedProgress),
                        observe(\.canGoBack), observe(\.canGoForward), observe(\.hasOnlySecureContent)]
    }

    private func sync(_ webView: WKWebView) {
        snapshot = Snapshot(url: webView.url, title: webView.title ?? "", isLoading: webView.isLoading,
                            progress: webView.estimatedProgress, canGoBack: webView.canGoBack,
                            canGoForward: webView.canGoForward, secure: webView.hasOnlySecureContent)
    }

    @MainActor fileprivate final class WeakBox {
        weak var session: BrowserSession?
    }

    private final class LegacyDelegate: NSObject, WKNavigationDelegate {
        let box: WeakBox
        init(box: WeakBox) { self.box = box }

        private static func commandKey(_ action: WKNavigationAction) -> Bool {
            #if os(macOS)
            action.modifierFlags.contains(.command)
            #else
            false
            #endif
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            let allow = box.session?.decide(url: action.request.url, isLink: action.navigationType == .linkActivated,
                                            newWindow: action.targetFrame == nil,
                                            commandKey: Self.commandKey(action)) ?? true
            decisionHandler(allow ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            let allow = box.session?.decide(response: response.response, canShow: response.canShowMIMEType,
                                            isMainFrame: response.isForMainFrame) ?? true
            decisionHandler(allow ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            box.session?.fail(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            box.session?.fail(error)
        }
    }
}
