import SwiftUI

@Observable @MainActor
final class ThreadPanelState {
    var tab: ThreadPanelTab?
    var full = false
    var citation: CitationRef?
    private(set) var browser: BrowserSession?

    struct CitationRef: Hashable {
        let message: String
        let index: Int
    }

    var isOpen: Bool { tab != nil }

    var tabs: [ThreadPanelTab] {
        ThreadPanelTab.allCases.filter { $0 != .browser || browser != nil }
    }

    func open(_ tab: ThreadPanelTab) {
        if tab == .browser && browser == nil { return }
        self.tab = tab
    }

    func toggle(_ tab: ThreadPanelTab) {
        if self.tab == tab { close() } else { open(tab) }
    }

    func close() {
        tab = nil
        full = false
        citation = nil
    }

    func showCitation(message: String, index: Int) {
        citation = CitationRef(message: message, index: index)
        tab = .sources
    }

    func openWeb(_ url: URL) {
        if let browser { browser.load(url) } else { browser = BrowserSession(url: url) }
        tab = .browser
    }

    func closeBrowser() {
        if tab == .browser { close() }
        browser?.close()
        browser = nil
    }
}
