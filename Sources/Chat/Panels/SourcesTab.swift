import SwiftUI

/// What the agent used in this thread (web: SourcesTab): a clicked citation first, at its
/// supporting passages; then the cited sources, the other retrieved sources, tool results per
/// turn, the memories it searched and sources found by search. Expanding a source shows its
/// text with every passage the thread's answers cited highlighted.
struct SourcesTab: View {
    let threadID: String?

    @Environment(AppStore.self) private var app
    @Environment(ChatStore.self) private var chat
    @Environment(ThreadPanelState.self) private var panel
    @State private var sources: [ThreadSource] = []
    @State private var memories: [ThreadMemory] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var expanded: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if threadID == nil {
            PanelNoThread(tab: .sources)
        } else {
            content
                .task(id: LoadKey(thread: threadID, streaming: chat.streaming)) { await load() }
                .onChange(of: DeriveKey(thread: threadID, count: chat.messages.count, streaming: chat.streaming),
                          initial: true) { _, key in
                    guard !key.streaming else { return }
                    derived = Derived(messages: chat.messages)
                }
        }
    }

    private struct LoadKey: Hashable { let thread: String?; let streaming: Bool }

    // MARK: Derived from the open thread's messages

    /// Citations, tool results and search hits across the thread's answers. Rebuilt when a reply
    /// finishes streaming or the message count changes, not on every streamed token.
    @State private var derived = Derived()

    private struct DeriveKey: Equatable { let thread: String?; let count: Int; let streaming: Bool }

    private struct Derived {
        /// Every passage the answers cited, per source key.
        var passages: [String: [String]] = [:]
        var toolResults: [ToolResult] = []
        var ragSources: [SearchHit] = []

        init() {}

        init(messages: [ChatMessage]) {
            // Assistant answers with their turn number.
            let turns = messages.filter { $0.role == "assistant" }.enumerated().map { ($0.offset + 1, $0.element) }
            for (_, message) in turns {
                guard let data = Citations(parts: message.parts) else { continue }
                for c in data.citations {
                    for e in c.evidence where !e.text.isEmpty && !(passages[e.key]?.contains(e.text) ?? false) {
                        passages[e.key, default: []].append(e.text)
                    }
                }
            }
            toolResults = turns.flatMap { number, message in
                message.parts.enumerated().compactMap { i, p -> ToolResult? in
                    guard Part.isTool(p), !Part.isCitations(p) else { return nil }
                    let state = p["state"]?.string ?? ""
                    guard ["output-available", "output-error", "denied", "output-denied"].contains(state) else { return nil }
                    return ToolResult(id: "\(message.id)-\(p["toolCallId"]?.string ?? String(i))",
                                      name: Part.humanize(Part.toolName(p)), turn: number,
                                      error: Part.toolError(p), state: state)
                }
            }
            // `data-rag-retrieval` parts: what a knowledge search returned.
            ragSources = turns.flatMap { _, message in
                message.parts.filter { Part.type($0) == "data-rag-retrieval" }
                    .flatMap { $0["data"]?["sources"]?.array ?? [] }
            }
            .enumerated().map { i, s in
                SearchHit(id: "\(i)-\(s["id"]?.string ?? "")", title: s["title"]?.string ?? "Source \(i + 1)",
                          url: s["url"]?.string.flatMap(URL.init(string:)))
            }
        }
    }

    private struct Focus {
        let quote: String
        let evidence: [(source: ThreadSource, passage: String)]
    }

    /// The citation the panel was opened at, resolved against the loaded sources (falling back
    /// to the answer's own copy of a source).
    private var focus: Focus? {
        guard let ref = panel.citation,
              let message = chat.messages.first(where: { $0.id == ref.message }),
              let data = Citations(parts: message.parts),
              let citation = data.citations.first(where: { $0.index == ref.index }) else { return nil }
        let evidence: [(ThreadSource, String)] = citation.evidence.compactMap { e in
            if let s = sources.first(where: { $0.key == e.key }) { return (s, e.text) }
            guard let s = data.source(e.key) else { return nil }
            return (ThreadSource(key: s.key, title: s.title, kind: s.kind, content: s.content,
                                 url: s.url?.absoluteString, cited: true), e.text)
        }
        return Focus(quote: citation.quote, evidence: evidence)
    }

    private struct ToolResult: Identifiable {
        let id: String
        let name: String
        let turn: Int
        let error: String?
        let state: String
    }

    private struct SearchHit: Identifiable { let id: String; let title: String; let url: URL? }

    // MARK: Views

    @ViewBuilder private var content: some View {
        let focus = focus
        let focusedKeys = Set(focus?.evidence.map(\.source.key) ?? [])
        let listed = sources.filter { !focusedKeys.contains($0.key) }
        let cited = listed.filter(\.cited)
        let retrieved = listed.filter { !$0.cited }
        let tools = derived.toolResults
        let rag = derived.ragSources
        let searched = memories.filter { $0.active != false }
        let passages = derived.passages

        if !loaded && error == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if focus == nil && sources.isEmpty && tools.isEmpty && rag.isEmpty && searched.isEmpty {
            ContentUnavailableView {
                Label("Nothing Used Yet", systemImage: "books.vertical")
            } description: {
                Text(error ?? "Sources the agent cites and tools it calls show up here.")
            }
        } else {
            ScrollViewReader { proxy in
                Form {
                    if let error {
                        Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    }
                    if let focus {
                        Section {
                            Text(focus.quote)
                                .italic()
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(.leading, 10)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(.tint).frame(width: 3)
                                }
                            ForEach(Array(focus.evidence.enumerated()), id: \.offset) { _, e in
                                SourceRow(source: e.source, passages: [e.passage], focused: true,
                                          expanded: binding(for: "focus:\(e.source.key)", default: true))
                            }
                        } header: {
                            HStack {
                                Text("This Citation")
                                Spacer()
                                Button("Show All") { panel.citation = nil }
                                    #if os(macOS)
                                    .buttonStyle(.link)
                                    #else
                                    .buttonStyle(.borderless)
                                    #endif
                                    .font(.callout)
                            }
                        }
                        .id("focus")
                    }
                    if !cited.isEmpty {
                        Section("Cited") {
                            ForEach(cited) { source in
                                SourceRow(source: source, passages: passages[source.key] ?? [], focused: false,
                                          expanded: binding(for: source.key))
                            }
                        }
                    }
                    if !retrieved.isEmpty {
                        Section("Also Retrieved") {
                            ForEach(retrieved) { source in
                                SourceRow(source: source, passages: [], focused: false,
                                          expanded: binding(for: source.key))
                            }
                        }
                    }
                    if !tools.isEmpty {
                        Section("Tool Results") {
                            ForEach(tools) { tool in
                                LabeledContent {
                                    Text("Turn \(tool.turn)")
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(tool.error == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.red.opacity(0.15)),
                                                    in: Capsule())
                                } label: {
                                    Label {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(tool.name)
                                            Text(tool.error ?? (tool.state == "output-available" ? "Completed" : "Denied"))
                                                .font(.caption)
                                                .foregroundStyle(tool.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                                                .lineLimit(2)
                                        }
                                    } icon: { Image(systemName: "wrench.and.screwdriver").foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    if !searched.isEmpty {
                        Section("Searched") {
                            ForEach(searched) { memory in
                                Label {
                                    LabeledContent(memory.name, value: memory.document_count.map {
                                        $0 == 1 ? "1 document" : "\($0) documents"
                                    } ?? "")
                                } icon: { Image(systemName: "cylinder.split.1x2").foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if !rag.isEmpty {
                        Section("Retrieved by Search") {
                            ForEach(rag) { hit in
                                if let url = hit.url {
                                    Link(destination: url) { Label(hit.title, systemImage: "globe") }
                                        .contextMenu { WebLinkMenu(url: url) }
                                } else {
                                    Label(hit.title, systemImage: "doc.text")
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .onChange(of: panel.citation) { _, ref in
                    if ref != nil { withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo("focus", anchor: .top) } }
                }
            }
        }
    }

    private func binding(for key: String, default open: Bool = false) -> Binding<Bool> {
        Binding(get: { expanded.contains(key) != open },
                set: { isOn in if isOn != open { expanded.insert(key) } else { expanded.remove(key) } })
    }

    private func load() async {
        guard let threadID, !chat.streaming else { return }
        do {
            async let s = app.api.threadSources(threadID)
            async let m = try? app.api.threadMemories(threadID)
            let (newSources, newMemories) = (try await s, await m ?? [])
            guard !Task.isCancelled else { return }
            sources = newSources
            memories = newMemories
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

/// One source: icon, title, kind and an excerpt; expanded, its text with the cited passages
/// highlighted. A focused source opens at its passage, with the full text one click away.
private struct SourceRow: View {
    let source: ThreadSource
    let passages: [String]
    let focused: Bool
    @Binding var expanded: Bool
    @State private var full = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                PassageText(content: source.content, passages: passages, window: focused && !full ? 280 : nil)
                HStack {
                    if focused, source.content.count > 600 {
                        Button(full ? "Show Passage" : "Show Full Source") { full.toggle() }
                            #if os(macOS)
                                    .buttonStyle(.link)
                                    #else
                                    .buttonStyle(.borderless)
                                    #endif
                    }
                    Spacer()
                    if let link = source.link {
                        Link(destination: link) { Label("Open", systemImage: "arrow.up.right.square") }
                            .contextMenu { WebLinkMenu(url: link) }
                    }
                }
                .font(.callout)
            }
            .padding(.top, 4)
        } label: {
            #if os(macOS)
            // The Mac disclosure only toggles from its chevron; make the whole label a real button
            // so a click, the keyboard and VoiceOver can all expand it.
            Button {
                withAnimation(reduceMotion ? nil : .snappy) { expanded.toggle() }
            } label: {
                labelContent.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            #else
            // iOS: the disclosure row itself toggles and carries the expanded trait.
            labelContent
            #endif
        }
        .help(source.link?.absoluteString ?? source.title)
    }

    private var labelContent: some View {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: source.isWeb ? "globe" : "doc.text")
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title).lineLimit(2)
                    if expanded {
                        Text(source.isWeb ? "Web page" : "Document").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(source.content.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(160))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if !passages.isEmpty && !focused {
                    Text(passages.count == 1 ? "1 passage" : "\(passages.count) passages")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
    }
}

/// Source text with the passages marked like a highlighter (web: SourcePassage's plain fallback).
/// With `window`, only that many characters around the first passage show.
private struct PassageText: View {
    let content: String
    let passages: [String]
    var window: Int?

    var body: some View {
        Text(attributed)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shown: (text: String, leading: Bool, trailing: Bool) {
        guard let window, let first = passages.lazy.compactMap({ content.range(of: $0) }).first else {
            return (content, false, false)
        }
        let lower = content.index(first.lowerBound, offsetBy: -window, limitedBy: content.startIndex) ?? content.startIndex
        let upper = content.index(first.upperBound, offsetBy: window, limitedBy: content.endIndex) ?? content.endIndex
        return (String(content[lower..<upper]), lower > content.startIndex, upper < content.endIndex)
    }

    private var attributed: AttributedString {
        let shown = shown
        var text = AttributedString((shown.leading ? "…" : "") + shown.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                    + (shown.trailing ? "…" : ""))
        for passage in passages where !passage.isEmpty {
            var searchStart = text.startIndex
            while let range = text[searchStart...].range(of: passage) {
                text[range].backgroundColor = Color.yellow.opacity(0.35)
                text[range].foregroundColor = Color.primary
                searchStart = range.upperBound
            }
        }
        return text
    }
}
