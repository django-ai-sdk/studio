import SwiftUI

/// Chat screen, laid out like the web app: an empty chat shows a centered greeting with the
/// composer in the middle of the window; once there are messages they scroll in a centered
/// column underneath a floating composer at the bottom. Files dropped anywhere attach.
/// Message rendering lives in MessageView.swift, input in Composer.swift.
struct ChatView: View {
    @Environment(ChatStore.self) private var chat
    @Environment(AppStore.self) private var app
    @State private var attachments = AttachmentStore()
    @State private var dropTargeted = false

    static let columnWidth: CGFloat = 768

    private var isHome: Bool { chat.messages.isEmpty && !chat.loading }

    @State private var panel = ThreadPanelState()
    /// Whether the conversation follows new content (the user is at the bottom).
    @State private var pinnedToBottom = true
    /// Height of the floating composer bar, which the conversation scrolls clear of.
    @State private var barHeight: CGFloat = 120
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// iPhone (and narrow iPad multitasking): tighter side margins.
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif
    private var sideMargin: CGFloat { compact ? 16 : 32 }

    private static var windowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    var body: some View {
        ThreadPanelSplit(threadID: chat.threadID) { chatColumn }
            .toolbar { topBar }
            .navigationTitle(title)
            #if os(macOS)
            .navigationSubtitle(chat.agent?.name ?? "")
            #else
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onChange(of: chat.threadID) { _, id in
                attachments.threadDidChange(to: id)
                panel.citation = nil
            }
            // Outermost, so the toolbar, alerts and sheets below also get the panel.
            .environment(panel)
            // Lets the View menu (StudioCommands) switch panel tabs.
            .focusedSceneValue(\.threadPanel, panel)
    }

    private var title: String {
        guard let id = chat.threadID else { return "New Chat" }
        let title = app.threads.first { $0.id == id }?.title ?? ""
        return title.isEmpty ? "Untitled" : title
    }

    // MARK: Top bar

    /// Web TopBar: the thread's title and agent (window title/subtitle), a toggle per panel tab
    /// and the thread's actions.
    @ToolbarContentBuilder private var topBar: some ToolbarContent {
        #if os(iOS)
        // No window subtitle on iOS: the agent's name sits under the title.
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(title).font(.headline).lineLimit(1)
                if let agent = chat.agent?.name, !agent.isEmpty {
                    Text(agent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
        }
        #endif
        // A new chat has no thread yet, so nothing for the panels to show.
        if let id = chat.threadID {
            ToolbarItem(placement: .primaryAction) {
                ThreadPanelToggles()
            }
            ToolbarItem(placement: .primaryAction) {
                ThreadActionsMenu(threadID: id)
            }
        }
    }

    private var chatColumn: some View {
        Group {
            if isHome { home } else { conversation }
        }
        .animation(.smooth(duration: 0.3), value: isHome)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: AttachmentStore.dropTypes, isTargeted: $dropTargeted) { attachments.drop($0, chat: chat) }
        .overlay {
            if dropTargeted {
                AttachmentDropOverlay(enabled: chat.agent?.file_upload == true).padding(12)
            }
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    // MARK: New chat

    private static let starters = [
        "What's the weather like today?",
        "Help me write an email",
        "Explain quantum computing",
        "Give me a recipe for dinner",
    ]

    private var home: some View {
        VStack(spacing: 24) {
            // The agent is picked in the composer's agent menu.
            Text("What can I help you with today?")
                .font(.title.weight(.medium))
                .multilineTextAlignment(.center)
            errorLabel
            Composer(attachments: attachments)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                ForEach(Self.starters, id: \.self) { starter in
                    Button { chat.send(starter) } label: {
                        Text(starter)
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                            .padding(12)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(chat.agentID == nil || chat.streaming)
                }
            }
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, sideMargin)
        .padding(.bottom, compact ? 16 : 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Conversation

    /// Space between the last message and the composer's top edge once scrolled to the bottom.
    private static let bottomGap: CGFloat = 40
    private static let bottomID = "conversation-bottom"

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    let lastID = chat.messages.last?.id
                    ForEach(chat.messages) { message in
                        let isLast = message.id == lastID
                        MessageView(message: message, streaming: chat.streaming && isLast, isLast: isLast)
                            .id(message.id)
                    }
                    // Scroll target below the last message, so scrolling to the bottom keeps the gap.
                    // The composer floats over the scroll view, so this also clears its height.
                    Color.clear.frame(height: barHeight + Self.bottomGap - 32).id(Self.bottomID)
                }
                .padding(.horizontal, sideMargin)
                .padding(.top, compact ? 16 : 28)
                .frame(maxWidth: Self.columnWidth)
                .frame(maxWidth: .infinity)
            }
            // No .defaultScrollAnchor(.bottom): on macOS 26 it draws a hairline across the chat.
            // Landing at the bottom is done by scrollTo after history loads (see onChange(of: loading)).
            .onScrollGeometryChange(for: ScrollMetrics.self) { g in
                ScrollMetrics(contentHeight: g.contentSize.height,
                              distanceToBottom: g.contentSize.height - g.visibleRect.maxY)
            } action: { old, new in
                // Growing content (a streaming reply, rows sizing lazily) doesn't unpin; only the
                // user scrolling does. While pinned, follow the growth so the end stays in view.
                guard old.contentHeight == new.contentHeight else {
                    if new.distanceToBottom < 40 { pinnedToBottom = true }
                    else if pinnedToBottom { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    return
                }
                let atBottom = new.distanceToBottom < 40
                if atBottom != pinnedToBottom { pinnedToBottom = atBottom }
            }
            .overlay { if chat.loading { ProgressView("Loading conversation…") } }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .contentMargins(.bottom, barHeight, for: .scrollIndicators)
            // An overlay rather than a bottom safe-area inset, so messages pass softly behind the
            // fade and the glass composer; the spacer above keeps the last one clear of it.
            .overlay(alignment: .bottom) {
                bottomBar(proxy)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
            }
            .onChange(of: chat.messages.count) { old, new in
                // Sending a message always brings the conversation back down. Growth of the
                // streaming reply is followed by the scroll-geometry handler above.
                if chat.streaming, new > old {
                    pinnedToBottom = true
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onChange(of: chat.threadID) { pinnedToBottom = true }
            .onChange(of: chat.loading) { _, loading in
                // A thread's history just arrived: land on its end once the lazy rows have sized.
                guard !loading else { return }
                pinnedToBottom = true
                // Lazy rows above the end (long markdown, tables) size late and move it; keep
                // re-landing for a moment, unless the user has scrolled away in the meantime.
                Task {
                    for i in 0..<8 {
                        if i >= 3 && !pinnedToBottom { break }
                        pinnedToBottom = true
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                        try? await Task.sleep(for: .milliseconds(i < 3 ? 80 : 150))
                    }
                }
            }
        }
    }

    private struct ScrollMetrics: Equatable {
        var contentHeight: CGFloat
        var distanceToBottom: CGFloat
    }

    /// Floating composer over the scrolling messages; the window background fades in just above
    /// its top edge so the footnote stays legible. The scroll-to-bottom button floats above it.
    private func bottomBar(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 8) {
            errorLabel
            Composer(attachments: attachments)
            Text("AI is not always right, please verify important information.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, sideMargin)
        .padding(.bottom, compact ? 6 : 10)
        .frame(maxWidth: Self.columnWidth)
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            // Starts a little above the composer so text scrolling under it dissolves instead of
            // being cut off; at rest the last message sits above the fade (see bottomGap).
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: Self.windowBackground, location: 0.3)],
                           startPoint: .top, endPoint: .bottom)
                .padding(.top, -24)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if !pinnedToBottom && !chat.loading {
                ScrollToBottomButton {
                    pinnedToBottom = true
                    withAnimation(.smooth(duration: 0.35)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
                .offset(y: -44)
                .transition(.opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.smooth(duration: 0.2), value: pinnedToBottom)
    }

    @ViewBuilder private var errorLabel: some View {
        if let error = chat.error {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if chat.canRetry {
                    Button("Retry") { Task { await chat.retry() } }
                        .buttonStyle(.borderless)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .textSelection(.enabled)
        }
    }
}

/// Round "jump to latest" button above the composer (Messages / ChatGPT style).
private struct ScrollToBottomButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.75))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(CircleChrome())
        .help("Scroll to bottom")
        .accessibilityLabel("Scroll to bottom")
    }
}

private struct CircleChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
    }
}
