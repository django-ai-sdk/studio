#if os(macOS)
import AppKit
#endif
import SwiftUI
import WebKit

/// The Browser tab's page: SwiftUI `WebView` on macOS 26, a `WKWebView` before; a failed load
/// shows a friendly error over it with a way out to the default browser.
struct BrowserView: View {
    let session: BrowserSession

    var body: some View {
        ZStack {
            page
            if let error = session.error {
                ContentUnavailableView {
                    Label("Can't Open This Page", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again", action: session.reload)
                    Button(openInBrowserTitle, action: session.openInDefaultBrowser)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            }
        }
    }

    @ViewBuilder private var page: some View {
        if #available(macOS 26, iOS 26, *) {
            WebView(session.page)
                .webViewBackForwardNavigationGestures(.enabled)
                .webViewMagnificationGestures(.enabled)
                .webViewLinkPreviews(.enabled)
                #if os(macOS)
                .webViewContextMenu { element in
                    if let link = element.linkURL {
                        Button("Open Link in Default Browser") { Platform.openExternally(link) }
                        Button("Copy Link") { Pasteboard.copy(link.absoluteString) }
                    }
                }
                #endif
        } else if let webView = session.webView {
            LegacyWebView(webView: webView)
        }
    }
}

/// macOS 15 / iOS 18–25: hosts the session's `WKWebView` (the session owns it, so history
/// survives tab switches).
#if os(macOS)
private struct LegacyWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
private struct LegacyWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif

// MARK: Toolbar

/// Safari-style header for the Browser tab: back/forward, reload/stop, the page's title and host
/// (lock for secure pages) with a load progress line, copy link, open in the default browser,
/// then the panel's own full width and close buttons (`trailing`).
struct BrowserToolbar<Trailing: View>: View {
    let session: BrowserSession
    @ViewBuilder var trailing: Trailing

    @State private var copied = false

    #if os(iOS)
    /// 44 pt hit area (HIG); the borderless glyph looks the same size.
    static var buttonSize: CGFloat { ThreadPanelView.buttonSize }
    #endif

    #if os(macOS)
    private static var spacing: CGFloat { 2 }
    private static var leadingPadding: CGFloat { 8 }
    private static var trailingPadding: CGFloat { 14 }
    #else
    // The 44 pt buttons fill the gaps themselves; keep room for the title on iPhone.
    private static var spacing: CGFloat { 0 }
    private static var leadingPadding: CGFloat { 2 }
    private static var trailingPadding: CGFloat { 4 }
    #endif

    var body: some View {
        HStack(spacing: Self.spacing) {
            Group {
                button("Back", systemImage: "chevron.backward", action: session.goBack)
                    .disabled(!session.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                button("Forward", systemImage: "chevron.forward", action: session.goForward)
                    .disabled(!session.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
            }
            address
                .padding(.horizontal, 6)
            Group {
                if session.isLoading {
                    // No ⌘. here: the composer uses it to stop the answer.
                    button("Stop Loading", systemImage: "xmark", action: session.stop)
                } else {
                    button("Reload Page", systemImage: "arrow.clockwise", action: session.reload)
                        .keyboardShortcut("r", modifiers: .command)
                }
                #if os(macOS)
                button(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link") {
                    session.copyLink()
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                button("Open in Default Browser", systemImage: "safari", action: session.openInDefaultBrowser)
                #else
                // Narrow on iPhone: link actions share one menu.
                Menu {
                    Button("Copy Link", systemImage: "link", action: session.copyLink)
                    Button("Open in Safari", systemImage: "safari", action: session.openInDefaultBrowser)
                    if let url = session.url { ShareLink(item: url) }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: Self.buttonSize, height: Self.buttonSize)
                }
                .accessibilityLabel("Page Actions")
                #endif
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            trailing
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.leading, Self.leadingPadding)
        .padding(.trailing, Self.trailingPadding)
        .frame(height: ThreadPanelView.headerHeight)
        .overlay(alignment: .bottom) { progressLine }
    }

    /// Title over host, centered like Safari's compact address field; right-click for link actions.
    private var address: some View {
        VStack(spacing: 0) {
            Text(session.title.isEmpty ? session.host : session.title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
            HStack(spacing: 3) {
                if session.isSecure {
                    Image(systemName: "lock.fill").imageScale(.small)
                        .accessibilityLabel("Secure connection")
                }
                Text(session.host)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .opacity(session.title.isEmpty ? 0 : 1)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .help(session.url?.absoluteString ?? "")
        .contextMenu {
            Button("Copy Link", systemImage: "link", action: session.copyLink)
            Button(openInBrowserTitle, systemImage: "safari", action: session.openInDefaultBrowser)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), \(session.host)\(session.isSecure ? ", secure" : "")")
    }

    @ViewBuilder private var progressLine: some View {
        if session.isLoading {
            GeometryReader { geo in
                Rectangle()
                    .fill(.tint)
                    .frame(width: geo.size.width * max(0.08, session.progress), height: 2)
                    .animation(.easeOut(duration: 0.2), value: session.progress)
            }
            .frame(height: 2)
            .transition(.opacity)
            .accessibilityHidden(true)
        }
    }

    private func button(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .contentTransition(.symbolEffect(.replace))
                #if os(macOS)
                .frame(width: 24, height: 22)
                #else
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                #endif
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: Link menu

/// "Open in Default Browser" on the Mac; iOS hands web pages to Safari.
var openInBrowserTitle: LocalizedStringKey {
    #if os(macOS)
    "Open in Default Browser"
    #else
    "Open in Safari"
    #endif
}

/// Context menu for a web link in the thread: links open in the panel's browser on click, so this
/// offers the default browser (⌘-click does the same) and copying.
struct WebLinkMenu: View {
    let url: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Open Link", systemImage: "globe") { openURL(url) }
        Button(openInBrowserTitle, systemImage: "safari") { Platform.openExternally(url) }
        Button("Copy Link", systemImage: "link") { Pasteboard.copy(url.absoluteString) }
    }
}
