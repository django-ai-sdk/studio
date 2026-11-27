import SwiftUI

/// Open/closed state of the thread side panel (web: useThreadPanel). ChatView owns one and
/// injects it with `.environment`, so the toolbar, the panel and message views can read it.
///
/// Message views can open the Sources tab at a citation with `showCitation(message:index:)`;
/// read it optionally (`@Environment(ThreadPanelState.self) private var panel: ThreadPanelState?`)
/// so previews and sheets without a panel keep working.
///
/// Web links opened in the thread (`ThreadPanelSplit` routes `openURL`) load in `browser`, shown
/// by the Browser tab; it lives until its close button or a switch to another thread.
@Observable @MainActor
final class ThreadPanelState {
    /// The open tab; nil when the panel is closed.
    var tab: ThreadPanelTab?
    /// The panel takes the whole detail area (the chat column hides).
    var full = false
    /// The citation the Sources tab shows first (web: sourcesPanelStore.focus).
    var citation: CitationRef?
    /// The embedded page; nil until a web link is opened (the Browser toggle only shows while set).
    private(set) var browser: BrowserSession?

    struct CitationRef: Hashable {
        let message: String
        let index: Int
    }

    var isOpen: Bool { tab != nil }

    /// The tabs to offer: the Browser tab only while a page is open.
    var tabs: [ThreadPanelTab] {
        ThreadPanelTab.allCases.filter { $0 != .browser || browser != nil }
    }

    func open(_ tab: ThreadPanelTab) {
        if tab == .browser && browser == nil { return }
        self.tab = tab
    }

    /// Top bar toggle: the open tab closes the panel, another tab switches to it.
    func toggle(_ tab: ThreadPanelTab) {
        if self.tab == tab { close() } else { open(tab) }
    }

    /// Hides the panel; an open page stays (its toggle brings it back).
    func close() {
        tab = nil
        full = false
        citation = nil
    }

    func showCitation(message: String, index: Int) {
        citation = CitationRef(message: message, index: index)
        tab = .sources
    }

    /// Loads a web page in the Browser tab (pushing onto its history) and shows it.
    func openWeb(_ url: URL) {
        if let browser { browser.load(url) } else { browser = BrowserSession(url: url) }
        tab = .browser
    }

    /// Closes the page (and the panel if it shows it); the Browser toggle goes away.
    func closeBrowser() {
        if tab == .browser { close() }
        browser?.close()
        browser = nil
    }
}
