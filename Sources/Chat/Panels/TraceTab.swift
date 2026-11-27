import SwiftUI

struct TraceTab: View {
    let threadID: String?
    @Environment(ChatStore.self) private var chat
    @State private var model = TraceModel()
    @State private var generation = 0

    private struct LoadKey: Hashable { let thread: String?; let generation: Int }

    var body: some View {
        TraceTabContent(threadID: threadID, model: model, reload: reload)
            .task(id: LoadKey(thread: threadID, generation: generation)) {
                guard let threadID else { model.reset(); return }
                await model.load(thread: threadID, api: chat.api)
                guard generation > 0 else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await model.load(thread: threadID, api: chat.api)
            }
            .onChange(of: chat.streaming) { was, streaming in
                guard was, !streaming, threadID != nil, chat.threadID == threadID else { return }
                generation += 1
            }
    }

    private func reload() async {
        guard let threadID else { return }
        await model.load(thread: threadID, api: chat.api)
    }
}

struct TraceTabContent: View {
    let threadID: String?
    let model: TraceModel
    let reload: () async -> Void
    @AppStorage("traceShowHooks") private var showHooks = false

    var body: some View {
        Group {
            if threadID == nil {
                ContentUnavailableView {
                    Label("No Trace Yet", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Send a message. Each turn's LLM calls, tool calls and timings show up here.")
                }
            } else if !model.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error, model.spans.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Trace", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await reload() } }
                }
            } else if model.turns.isEmpty {
                ContentUnavailableView {
                    Label("No Spans Recorded", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Spans appear here once the agent has answered in this thread.")
                } actions: {
                    Button("Refresh") { Task { await reload() } }
                }
            } else {
                TraceTimeline(model: model, showHooks: $showHooks, reload: reload)
            }
        }
        .onAppear { model.showHooks = showHooks }
        .onChange(of: showHooks) { _, value in model.showHooks = value }
    }
}

private struct TraceTimeline: View {
    let model: TraceModel
    @Binding var showHooks: Bool
    let reload: () async -> Void
    @State private var width: CGFloat = 340
    @State private var selected: String?
    @State private var collapsedSpans: Set<String> = []
    @State private var collapsedTurns: Set<String> = []

    private var layout: TraceLayout { TraceLayout(width: width) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                TraceSummary(model: model, layout: layout, showHooks: $showHooks, reload: reload,
                             expandAll: { collapsedSpans = []; collapsedTurns = [] },
                             collapseAll: { collapsedTurns = Set(model.turns.map(\.id)) })
                ForEach(model.turns) { turn in
                    TraceTurnCard(
                        turn: turn, layout: layout, selected: $selected,
                        collapsedSpans: $collapsedSpans,
                        expanded: Binding(
                            get: { !collapsedTurns.contains(turn.id) },
                            set: { if $0 { collapsedTurns.remove(turn.id) } else { collapsedTurns.insert(turn.id) } }
                        )
                    )
                }
            }
            .padding(layout.wide ? 20 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

struct TraceLayout: Equatable {
    let width: CGFloat
    var wide: Bool { width >= 620 }
    var track: CGFloat { wide ? min(max(width * 0.32, 180), 520) : max(48, min(width * 0.17, 100)) }
    var indent: CGFloat { wide ? 16 : 8 }
    var maxIndentDepth: Int { wide ? 16 : 5 }
}

private struct TraceSummary: View {
    let model: TraceModel
    let layout: TraceLayout
    @Binding var showHooks: Bool
    let reload: () async -> Void
    let expandAll: () -> Void
    let collapseAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Usage").font(.headline)
                Spacer()
                if model.loading { ProgressView().controlSize(.mini) }
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh Trace")
                    .accessibilityLabel("Refresh trace")
                    .disabled(model.loading)
                Menu {
                    Toggle("Show Hook Spans", isOn: $showHooks)
                    Divider()
                    Button("Expand All Turns", action: expandAll)
                    Button("Collapse All Turns", action: collapseAll)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Trace Options")
                .accessibilityLabel("Trace options")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: layout.wide ? 110 : 88), spacing: 8, alignment: .leading)],
                      alignment: .leading, spacing: 8) {
                TraceStat(label: "Turns", value: "\(model.turns.count)")
                TraceStat(label: "Spans", value: "\(model.visibleSpanCount)")
                TraceStat(label: "Time", value: TraceFormat.duration(model.totalDurationMs))
                if let tokens = model.usage?.total_tokens ?? turnsTokens {
                    TraceStat(label: "Tokens", value: TraceFormat.tokens(tokens),
                              help: tokenHelp)
                }
                if let cost = model.totalCost { TraceStat(label: "Cost", value: TraceFormat.cost(cost)) }
                if model.errorCount > 0 {
                    TraceStat(label: "Errors", value: "\(model.errorCount)", tint: .red)
                }
            }

            if let subagents = model.usage?.by_subagent, !subagents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("By agent").font(.caption).foregroundStyle(.secondary)
                    ForEach(subagents.sorted { ($0.value.total_tokens ?? 0) > ($1.value.total_tokens ?? 0) }, id: \.key) { _, usage in
                        HStack {
                            Label(usage.agent_name.flatMap { $0.isEmpty ? nil : $0 } ?? "Subagent", systemImage: "person.2.wave.2")
                                .lineLimit(1)
                            Spacer()
                            Text(TraceFormat.tokens(usage.total_tokens) + " tokens")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    private var turnsTokens: Int? {
        let values = model.turns.compactMap(\.tokens)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private var tokenHelp: String? {
        guard let u = model.usage, let p = u.prompt_tokens, let c = u.completion_tokens else { return nil }
        return "\(p.formatted()) prompt · \(c.formatted()) completion"
    }
}

private struct TraceStat: View {
    let label: String
    let value: String
    var help: String? = nil
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }
}
