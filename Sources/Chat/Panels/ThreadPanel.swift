#if os(macOS)
import AppKit
#endif
import SwiftUI

/// Tabs of the thread side panel (mirrors the web app's ThreadPanel: Insights, Trace, Sources, Agent),
/// plus Browser, the embedded page web links in the thread open in (only offered while one is open).
/// The shell (top bar toggles, split view, full width, link routing) is `ThreadPanelSplit` below;
/// ChatView puts the toggles in its toolbar (`ThreadPanelToggles`). Each tab is its own view.
enum ThreadPanelTab: String, CaseIterable, Identifiable {
    case insights, trace, sources, agent, browser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insights: "Oversight"
        case .trace: "Trace"
        case .sources: "Sources"
        case .agent: "Agent"
        case .browser: "Web Page"
        }
    }

    var systemImage: String {
        switch self {
        case .insights: "checkmark.shield"
        case .trace: "point.3.connected.trianglepath.dotted"
        case .sources: "books.vertical"
        case .agent: "cpu"
        case .browser: "globe"
        }
    }

    /// ⌥⌘1…5
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1)))
    }
}

/// Content for one tab. `threadID` is nil on a new chat (no thread yet).
struct ThreadPanelContent: View {
    let tab: ThreadPanelTab
    let threadID: String?

    @Environment(ThreadPanelState.self) private var panel

    var body: some View {
        switch tab {
        case .insights: InsightsTab(threadID: threadID)
        case .trace: TraceTab(threadID: threadID)
        case .sources: SourcesTab(threadID: threadID)
        case .agent: AgentTab(threadID: threadID)
        case .browser:
            if let browser = panel.browser { BrowserView(session: browser) }
        }
    }
}

// MARK: Toolbar toggles

/// One toggle per tab for the chat's toolbar; pressing the open tab closes the panel.
/// On iPhone (compact width) they collapse into one menu button.
struct ThreadPanelToggles: View {
    @Environment(ThreadPanelState.self) private var panel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        #if os(iOS)
        if sizeClass == .compact {
            Menu {
                ForEach(panel.tabs) { tab in
                    Toggle(isOn: Binding(get: { panel.tab == tab }, set: { _ in panel.toggle(tab) })) {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                }
            } label: {
                Label("Thread Panel", systemImage: "sidebar.right")
            }
        } else {
            toggles
        }
        #else
        toggles
        #endif
    }

    private var toggles: some View {
        ControlGroup {
            ForEach(panel.tabs) { tab in
                Toggle(isOn: Binding(get: { panel.tab == tab }, set: { _ in panel.toggle(tab) })) {
                    Label(tab.title, systemImage: tab.systemImage)
                }
                .help("\(tab.title) (⌥⌘\(String(tab.shortcut.character)))")
                .keyboardShortcut(tab.shortcut, modifiers: [.command, .option])
            }
        } label: {
            Label("Thread Panel", systemImage: "sidebar.right")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
    }
}

// MARK: Split

/// The chat (`main`) and the open panel side by side with a draggable divider; the panel's width
/// is remembered. In full width the chat column hides and the panel fills the detail area.
///
/// Web links opened anywhere inside (answer markdown, source chips, the Sources tab — anything
/// using the `openURL` environment action) load in the panel's Browser tab, so the reader stays
/// in the thread. ⌘-click and other schemes go to the system as usual.
#if os(macOS)
struct ThreadPanelSplit<Main: View>: View {
    let threadID: String?
    @ViewBuilder var main: Main

    @Environment(ThreadPanelState.self) private var panel
    @AppStorage("studio.threadPanel.width") private var width: Double = 460
    @State private var dragStart: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var minWidth: Double { 340 }
    static var mainMinWidth: Double { 420 }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if !(panel.full && panel.isOpen) {
                    main.frame(maxWidth: .infinity)
                }
                if let tab = panel.tab {
                    if !panel.full { divider(total: geo.size.width) }
                    ThreadPanelView(tab: tab, threadID: threadID)
                        .frame(width: panel.full ? nil : clamp(width, total: geo.size.width))
                        .frame(maxWidth: panel.full ? .infinity : nil)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        // Reduce Motion: no slide, and the panel appears/resizes without animating.
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: panel.isOpen)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: panel.full)
        .environment(\.openURL, OpenURLAction { url in
            let web = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            let command = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            guard web, !command else { return .systemAction }
            panel.openWeb(url)
            return .handled
        })
        // The page belongs to the thread it was opened from.
        .onChange(of: threadID) { old, _ in
            if old != nil { panel.closeBrowser() }
        }
    }

    private func clamp(_ w: Double, total: Double) -> Double {
        let upper = max(Self.minWidth, min(total * 0.65, total - Self.mainMinWidth))
        return min(max(w, Self.minWidth), upper)
    }

    private func divider(total: Double) -> some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? clamp(width, total: total)
                                dragStart = start
                                width = clamp(start - value.translation.width, total: total)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
            .zIndex(1)
            .accessibilityHidden(true)
    }
}
#else
/// iOS: the chat stays put and the panel is presented over it — an inspector column on iPad
/// (regular width), a sheet with medium/large detents on iPhone. Full width is the large detent
/// on iPhone and a full screen cover on iPad. Web links route to the panel's Browser tab, as on
/// the Mac (there's no ⌘-click; the link menu offers the default browser).
struct ThreadPanelSplit<Main: View>: View {
    let threadID: String?
    @ViewBuilder var main: Main

    @Environment(ThreadPanelState.self) private var panel
    @Environment(\.horizontalSizeClass) private var sizeClass
    // Presented content doesn't reliably inherit the environment; re-inject what the tabs read.
    @Environment(AppStore.self) private var app: AppStore?
    @Environment(ChatStore.self) private var chat: ChatStore?

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        main
            .inspector(isPresented: presented(!compact && !panel.full)) {
                content.inspectorColumnWidth(min: 320, ideal: 400, max: 560)
            }
            .sheet(isPresented: presented(compact)) {
                content
                    .presentationDetents([.medium, .large], selection: detent)
                    // The chat behind stays inert: its toolbar toggles would otherwise fight the sheet.
                    .presentationBackgroundInteraction(.disabled)
                    .presentationContentInteraction(.scrolls)
                    .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: presented(!compact && panel.full)) {
                content
            }
            .environment(\.openURL, openURL)
            .onChange(of: threadID) { old, _ in
                if old != nil { panel.closeBrowser() }
            }
    }

    @ViewBuilder private var content: some View {
        if let tab = panel.tab {
            ThreadPanelView(tab: tab, threadID: threadID)
                .environment(\.openURL, openURL)
                .environment(panel)
                .environment(app)
                .environment(chat)
        }
    }

    private var openURL: OpenURLAction {
        OpenURLAction { [panel] url in
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .systemAction }
            panel.openWeb(url)
            return .handled
        }
    }

    /// Shown while a tab is open and `condition` holds; dismissing (swipe down, …) closes the panel.
    private func presented(_ condition: Bool) -> Binding<Bool> {
        Binding(get: { panel.isOpen && condition }, set: { if !$0 && condition { panel.close() } })
    }

    /// iPhone: the large detent is "full width".
    private var detent: Binding<PresentationDetent> {
        Binding(get: { panel.full ? .large : .medium }, set: { panel.full = $0 == .large })
    }
}
#endif

// MARK: Panel

/// The docked panel: a header (tab, full width, close) over the tab's content, on an
/// inspector-like background.
struct ThreadPanelView: View {
    let tab: ThreadPanelTab
    let threadID: String?

    @Environment(ThreadPanelState.self) private var panel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ThreadPanelContent(tab: tab, threadID: threadID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(tab)
        }
        #if os(macOS)
        .background(PanelMaterial())
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thread details: \(tab.title)")
        .background {
            // Esc leaves full width (web: same).
            if panel.full {
                Button("Exit Full Width") { panel.full = false }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var header: some View {
        if tab == .browser, let browser = panel.browser {
            BrowserToolbar(session: browser) { chromeButtons }
        } else {
            HStack(spacing: 8) {
                title
                Spacer()
                chromeButtons
            }
            .padding(.horizontal, 14)
            .frame(height: Self.headerHeight)
        }
    }

    #if os(macOS)
    static let buttonSize: CGFloat = 22
    static let headerHeight: CGFloat = 40
    #else
    /// 44 pt hit area (HIG); the borderless glyph looks the same size.
    static let buttonSize: CGFloat = 44
    static let headerHeight: CGFloat = 52
    #endif

    /// The tab's name; on iOS a menu to switch tabs (the toolbar may be covered by the sheet).
    @ViewBuilder private var title: some View {
        let label = Label(tab.title, systemImage: tab.systemImage)
            .font(.headline)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.primary)
        #if os(iOS)
        Menu {
            Picker("Tab", selection: Binding(get: { tab }, set: { panel.open($0) })) {
                ForEach(panel.tabs) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
        } label: {
            HStack(spacing: 4) {
                label
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .frame(minHeight: Self.buttonSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #else
        label
        #endif
    }

    /// Full width and close; on the Browser tab, close also closes the page.
    private var chromeButtons: some View {
        Group {
            Button {
                panel.full.toggle()
            } label: {
                Image(systemName: panel.full ? "arrow.down.right.and.arrow.up.left"
                                             : "arrow.up.left.and.arrow.down.right")
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
            }
            .help(panel.full ? "Exit Full Width (Esc)" : "Full Width")
            .accessibilityLabel(panel.full ? "Exit full width" : "Full width")
            Button {
                if tab == .browser { panel.closeBrowser() } else { panel.close() }
            } label: {
                Image(systemName: "xmark").frame(width: Self.buttonSize, height: Self.buttonSize)
            }
            .help(tab == .browser ? "Close Page" : "Close Panel")
            .accessibilityLabel(tab == .browser ? "Close page" : "Close panel")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }
}

#if os(macOS)
/// The window's sidebar material behind the panel, so it reads as an inspector column.
private struct PanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
#endif

// MARK: Shared panel bits

/// Friendly empty state for a tab on a new chat.
struct PanelNoThread: View {
    let tab: ThreadPanelTab

    var body: some View {
        ContentUnavailableView {
            Label("No Conversation Yet", systemImage: tab.systemImage)
        } description: {
            Text(description)
        }
    }

    private var description: String {
        switch tab {
        case .insights: "Send a message to start a thread. Checks on each answer show up here."
        case .trace: "Send a message to start a thread. What the agent did, step by step, shows up here."
        case .sources: "Send a message to start a thread. Sources the agent cites and tools it calls show up here."
        case .agent: "Send a message to start a thread with the selected agent."
        case .browser: "Web links you open in the thread show up here."
        }
    }
}

/// "31.4K" token counts.
func formatTokens(_ n: Int) -> String {
    n >= 1000 ? (Double(n) / 1000).formatted(.number.precision(.fractionLength(n >= 10_000 ? 0 : 1))) + "K" : "\(n)"
}
