import SwiftUI

struct ChatView: View {
    @Environment(ChatStore.self) private var chat
    @Environment(AppStore.self) private var app
    @State private var attachments = AttachmentStore()
    @State private var dropTargeted = false

    static let columnWidth: CGFloat = 768

    private var isHome: Bool { chat.messages.isEmpty && !chat.loading }

    @State private var panel = ThreadPanelState()
    @State private var pinnedToBottom = true
    @State private var barHeight: CGFloat = 120
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
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
            .environment(panel)
            .focusedSceneValue(\.threadPanel, panel)
    }

    private var title: String {
        guard let id = chat.threadID else { return "New Chat" }
        let title = app.threads.first { $0.id == id }?.title ?? ""
        return title.isEmpty ? "Untitled" : title
    }

    @ToolbarContentBuilder private var topBar: some ToolbarContent {
        #if os(iOS)
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

    private static let starters = [
        "What's the weather like today?",
        "Help me write an email",
        "Explain quantum computing",
        "Give me a recipe for dinner",
    ]

    private var home: some View {
        VStack(spacing: 24) {
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
                    Color.clear.frame(height: barHeight + Self.bottomGap - 32).id(Self.bottomID)
                }
                .padding(.horizontal, sideMargin)
                .padding(.top, compact ? 16 : 28)
                .frame(maxWidth: Self.columnWidth)
                .frame(maxWidth: .infinity)
            }
            .onScrollGeometryChange(for: ScrollMetrics.self) { g in
                ScrollMetrics(contentHeight: g.contentSize.height,
                              distanceToBottom: g.contentSize.height - g.visibleRect.maxY)
            } action: { old, new in
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
            .overlay(alignment: .bottom) {
                bottomBar(proxy)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
            }
            .onChange(of: chat.messages.count) { old, new in
                if chat.streaming, new > old {
                    pinnedToBottom = true
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onChange(of: chat.threadID) { pinnedToBottom = true }
            .onChange(of: chat.loading) { _, loading in
                guard !loading else { return }
                pinnedToBottom = true
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
