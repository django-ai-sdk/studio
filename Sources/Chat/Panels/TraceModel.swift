import Foundation
import Observation

/// What a span did, from its Haystack operation name and tags.
enum TraceSpanKind: Hashable, Sendable {
    case agent, step, llm, tool, retrieval, component, pipeline, subagent, hook, other

    var label: String {
        switch self {
        case .agent: "Agent run"
        case .step: "Step"
        case .llm: "LLM call"
        case .tool: "Tool call"
        case .retrieval: "Retrieval"
        case .component: "Component"
        case .pipeline: "Pipeline"
        case .subagent: "Handoff"
        case .hook: "Hook"
        case .other: "Span"
        }
    }

    var systemImage: String {
        switch self {
        case .agent: "play.circle"
        case .step: "arrow.turn.down.right"
        case .llm: "sparkles"
        case .tool: "wrench.and.screwdriver"
        case .retrieval: "doc.text.magnifyingglass"
        case .component: "square.stack.3d.up"
        case .pipeline: "flowchart"
        case .subagent: "person.2.wave.2"
        case .hook: "link"
        case .other: "circle.dotted"
        }
    }
}

/// One span, placed in its turn's tree and timeline.
struct TraceNode: Identifiable, Hashable, Sendable {
    let span: TraceSpanOut
    let kind: TraceSpanKind
    let title: String
    /// Model, tool description, hook point… shown next to the title.
    let detail: String?
    let start: Date
    let end: Date?
    let error: String?
    var depth = 0
    var children: [TraceNode] = []
    /// Position on the turn's timeline, 0…1.
    var offset: Double = 0
    var width: Double = 0

    var id: String { span.id }
    var isRunning: Bool { span.ended_at == nil }
    var durationMs: Double? { span.duration_ms ?? end.map { $0.timeIntervalSince(start) * 1000 } }
    var model: String? { span.model_name.flatMap { $0.isEmpty ? nil : $0 } }
}

/// One agent answer (user message → reply) with the spans that produced it.
struct TraceTurn: Identifiable, Hashable, Sendable {
    let id: String
    var number: Int?
    var prompt: String?
    var roots: [TraceNode]
    var spanCount: Int
    var start: Date
    var end: Date
    var tokens: Int?
    var promptTokens: Int?
    var completionTokens: Int?
    var models: [String]
    var errorCount: Int
    var cost: Double?

    var durationMs: Double { end.timeIntervalSince(start) * 1000 }
    var title: String { number.map { "Turn \($0)" } ?? "Run" }
}

/// Loads a thread's spans and turns them into per-turn trees. Held by `TraceTab` as `@State`.
@Observable @MainActor
final class TraceModel {
    private(set) var spans: [TraceSpanOut] = []
    private(set) var usage: TraceTokenUsage?
    private(set) var turns: [TraceTurn] = []
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var error: String?
    var showHooks = false { didSet { if showHooks != oldValue { rebuild() } } }

    private var history: [ChatMessage] = []
    private var costs: [TraceTurnCost] = []
    private var thread: String?

    var totalDurationMs: Double { turns.reduce(0) { $0 + $1.durationMs } }
    var totalCost: Double? {
        let values = turns.compactMap(\.cost)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    var errorCount: Int { turns.reduce(0) { $0 + $1.errorCount } }
    var visibleSpanCount: Int { turns.reduce(0) { $0 + $1.spanCount } }

    func reset() {
        spans = []; usage = nil; turns = []; history = []; costs = []
        loaded = false; error = nil; thread = nil
    }

    func load(thread: String, api: API) async {
        if self.thread != thread { reset(); self.thread = thread }
        loading = true
        defer { loading = false }
        do {
            async let spans = api.threadTraces(thread: thread)
            async let usage = try? api.threadTokens(thread: thread)
            async let history = try? api.history(thread: thread)
            async let costs = api.threadTurnCosts(thread: thread)
            let (s, u, h, c) = try await (spans, usage, history, costs)
            guard self.thread == thread, !Task.isCancelled else { return }
            self.spans = s
            self.usage = u
            self.history = h ?? self.history
            self.costs = c ?? []
            error = nil
            rebuild()
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            guard self.thread == thread else { return }
            self.error = error.localizedDescription
        }
        loaded = true
    }

    /// For previews and offscreen rendering: use already-decoded data.
    func set(spans: [TraceSpanOut], usage: TraceTokenUsage?, history: [ChatMessage], costs: [TraceTurnCost] = []) {
        self.spans = spans; self.usage = usage; self.history = history; self.costs = costs
        loaded = true
        rebuild()
    }

    private func rebuild() {
        turns = TraceBuilder.turns(spans: spans, history: history, costs: costs, showHooks: showHooks)
    }
}

/// Pure functions from flat spans to turn trees.
enum TraceBuilder {
    static func turns(spans: [TraceSpanOut], history: [ChatMessage], costs: [TraceTurnCost], showHooks: Bool) -> [TraceTurn] {
        guard !spans.isEmpty else { return [] }
        let byID = Dictionary(spans.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let parentIDs = Set(spans.compactMap(\.parent_id))

        // Root of each span, to group spans without a message id by run.
        func root(of span: TraceSpanOut) -> String {
            var current = span
            var seen: Set<String> = [span.id]
            while let p = current.parent_id, let parent = byID[p], seen.insert(p).inserted { current = parent }
            return current.id
        }
        var groups: [String: [TraceSpanOut]] = [:]
        var order: [String] = []
        for span in spans {
            let key = span.message_id ?? root(of: span)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(span)
        }

        // Turn numbers and prompts from the thread history.
        var info: [String: (number: Int, prompt: String?)] = [:]
        var lastUser: ChatMessage?
        var number = 0
        for message in history {
            if message.role == "user" { lastUser = message; continue }
            guard message.role == "assistant" else { continue }
            number += 1
            info[message.id] = (number, lastUser.flatMap(promptText))
        }
        let costByMessage = pairCosts(costs, answers: history.filter { $0.role == "assistant" })

        var turns: [TraceTurn] = []
        for key in order {
            guard let group = groups[key] else { continue }
            let visible = showHooks ? group : group.filter { kind(of: $0) != .hook }
            guard !visible.isEmpty else { continue }
            let roots = tree(visible, all: byID)
            let starts = group.compactMap { TraceDate.parse($0.started_at) }
            guard let start = starts.min() else { continue }
            let ends = group.compactMap { span -> Date? in
                if let e = span.ended_at.flatMap(TraceDate.parse) { return e }
                guard let s = TraceDate.parse(span.started_at) else { return nil }
                return s.addingTimeInterval((span.duration_ms ?? 0) / 1000)
            }
            let end = max(ends.max() ?? start, start)
            var placed = roots
            let total = max(end.timeIntervalSince(start), 0.001)
            for i in placed.indices { place(&placed[i], start: start, total: total, depth: 0) }

            // LLM calls are the leaves that carry usage (as the backend's token totals count them).
            let leaves = group.filter { !parentIDs.contains($0.id) && $0.total_tokens != nil }
            let tokens = leaves.isEmpty ? nil : leaves.reduce(0) { $0 + ($1.total_tokens ?? 0) }
            let promptTokens = leaves.compactMap(\.prompt_tokens)
            let completionTokens = leaves.compactMap(\.completion_tokens)
            var models: [String] = []
            for span in group.sorted(by: { $0.started_at < $1.started_at }) {
                if let m = span.model_name, !m.isEmpty, !models.contains(m) { models.append(m) }
            }
            let meta = info[key]
            turns.append(TraceTurn(
                id: key, number: meta?.number, prompt: meta?.prompt,
                roots: placed, spanCount: visible.count, start: start, end: end,
                tokens: tokens,
                promptTokens: promptTokens.isEmpty ? nil : promptTokens.reduce(0, +),
                completionTokens: completionTokens.isEmpty ? nil : completionTokens.reduce(0, +),
                models: models,
                errorCount: group.filter { errorText($0) != nil }.count,
                cost: costByMessage[key]
            ))
        }
        // Newest first, like the web app's trace tab.
        return turns.sorted { $0.start > $1.start }
    }

    /// Tree of `spans`; a span whose parent is hidden hangs under its nearest visible ancestor.
    private static func tree(_ spans: [TraceSpanOut], all: [String: TraceSpanOut]) -> [TraceNode] {
        let visibleIDs = Set(spans.map(\.id))
        func visibleParent(_ span: TraceSpanOut) -> String? {
            var seen: Set<String> = [span.id]
            var p = span.parent_id
            while let id = p, seen.insert(id).inserted {
                if visibleIDs.contains(id) { return id }
                p = all[id]?.parent_id
            }
            return nil
        }
        var childrenOf: [String: [TraceSpanOut]] = [:]
        var roots: [TraceSpanOut] = []
        for span in spans {
            if let p = visibleParent(span) { childrenOf[p, default: []].append(span) } else { roots.append(span) }
        }
        func build(_ span: TraceSpanOut, guardSet: Set<String>) -> TraceNode {
            var node = node(for: span)
            let kids = (childrenOf[span.id] ?? []).filter { !guardSet.contains($0.id) }
            node.children = kids.sorted(by: earlier).map { build($0, guardSet: guardSet.union([span.id])) }
            return node
        }
        return roots.sorted(by: earlier).map { build($0, guardSet: []) }
    }

    private static func earlier(_ a: TraceSpanOut, _ b: TraceSpanOut) -> Bool {
        let (x, y) = (TraceDate.parse(a.started_at) ?? .distantPast, TraceDate.parse(b.started_at) ?? .distantPast)
        return x == y ? (a.duration_ms ?? 0) > (b.duration_ms ?? 0) : x < y
    }

    private static func place(_ node: inout TraceNode, start: Date, total: TimeInterval, depth: Int) {
        node.depth = depth
        let s = node.start.timeIntervalSince(start)
        let d = (node.durationMs ?? 0) / 1000
        node.offset = min(max(s / total, 0), 1)
        node.width = min(max(d / total, 0), 1 - node.offset)
        for i in node.children.indices { place(&node.children[i], start: start, total: total, depth: depth + 1) }
    }

    static func node(for span: TraceSpanOut) -> TraceNode {
        let k = kind(of: span)
        let tags = span.tags ?? [:]
        let tag = { (key: String) in tags[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        let model = span.model_name.flatMap { $0.isEmpty ? nil : $0 }
        let title: String
        var detail: String?
        switch k {
        case .agent:
            title = span.agent_name.flatMap { $0.isEmpty ? nil : $0 } ?? "Agent run"
            if let steps = tags["haystack.agent.steps_taken"]?.number { detail = "\(Int(steps)) step\(steps == 1 ? "" : "s")" }
        case .step:
            // Haystack counts steps from 0.
            title = tags["haystack.agent.step"]?.number.map { "Step \(Int($0) + 1)" } ?? "Step"
        case .llm:
            title = tag("haystack.component.name").map(humanize) ?? "LLM call"
            detail = model
        case .tool:
            title = tag("haystack.tool.name").map(humanize) ?? "Tool call"
        case .retrieval, .component:
            title = tag("haystack.component.name").map(humanize) ?? k.label
            detail = tag("haystack.component.type")
        case .pipeline:
            title = "Pipeline"
        case .subagent:
            title = span.agent_name.flatMap { $0.isEmpty ? nil : $0 } ?? tag("django_ai_sdk.subagent.name") ?? "Subagent"
            detail = "Handoff"
        case .hook:
            title = tag("haystack.agent.hook.name") ?? "Hook"
            detail = tag("haystack.agent.hook.point").map(humanize)
        case .other:
            title = span.operation_name.split(separator: ".").suffix(2).joined(separator: " ").replacingOccurrences(of: "_", with: " ").capitalized
        }
        let start = TraceDate.parse(span.started_at) ?? .distantPast
        return TraceNode(span: span, kind: k, title: title, detail: detail, start: start,
                         end: span.ended_at.flatMap(TraceDate.parse), error: errorText(span))
    }

    static func kind(of span: TraceSpanOut) -> TraceSpanKind {
        let op = span.operation_name.lowercased()
        let tags = span.tags ?? [:]
        if op.contains("subagent") || op.contains("handoff") { return .subagent }
        if op.hasSuffix(".hook") { return .hook }
        if op.hasSuffix("step.llm") || op.contains("chat_generator") || op.contains("generator.run") { return .llm }
        if op.hasSuffix("step.tool") || op.contains("tool") { return .tool }
        if op.hasSuffix("agent.step") { return .step }
        if op.hasSuffix("agent.run") { return .agent }
        if op.contains("pipeline") { return .pipeline }
        if op.contains("component") {
            let text = ((tags["haystack.component.type"]?.string ?? "") + (tags["haystack.component.name"]?.string ?? "")).lowercased()
            if text.contains("retriev") || text.contains("embedder") || text.contains("ranker") { return .retrieval }
            if text.contains("generator") || text.contains("chat") && span.total_tokens != nil { return .llm }
            return .component
        }
        if op.contains("retriev") { return .retrieval }
        if op.contains("llm") || op.contains("chat") { return .llm }
        return .other
    }

    /// The span's error, from any truthy `*error*` tag (`haystack.tool.error: true`, an error message…).
    static func errorText(_ span: TraceSpanOut) -> String? {
        for (key, value) in (span.tags ?? [:]).sorted(by: { $0.key < $1.key }) where key.lowercased().contains("error") {
            switch value {
            case .bool(true): return "\(humanize(String(key.split(separator: ".").dropLast().last ?? "Span"))) failed"
            case .string(let s) where !s.isEmpty && s.lowercased() != "false" && s.lowercased() != "none": return s
            case .object(let o) where !o.isEmpty: return value.pretty
            case .number(let n) where n != 0: return "Error \(Int(n))"
            default: continue
            }
        }
        return nil
    }

    /// Splits tags into what went in, what came out, and the rest. Stringified JSON is parsed.
    static func sections(_ span: TraceSpanOut) -> (input: JSON?, output: JSON?, attributes: JSON?) {
        var input: [String: JSON] = [:], output: [String: JSON] = [:], rest: [String: JSON] = [:]
        for (key, raw) in span.tags ?? [:] {
            let value = parsed(raw)
            let short = key.hasPrefix("haystack.") ? String(key.dropFirst("haystack.".count)) : key
            let last = key.split(separator: ".").last.map(String.init) ?? key
            if ["input", "input_data", "messages", "arguments", "parameters", "prompt"].contains(last) {
                input[short] = value
            } else if ["output", "result", "results", "replies", "response", "output_data"].contains(last) {
                output[short] = value
            } else {
                rest[short] = value
            }
        }
        func one(_ d: [String: JSON]) -> JSON? { d.isEmpty ? nil : d.count == 1 ? d.first!.value : .object(d) }
        return (one(input), one(output), rest.isEmpty ? nil : .object(rest))
    }

    private static func parsed(_ value: JSON) -> JSON {
        guard let s = value.string, let first = s.first, first == "{" || first == "[",
              let json = try? JSONDecoder().decode(JSON.self, from: Data(s.utf8)) else { return value }
        return json
    }

    static func humanize(_ name: String) -> String {
        let spaced = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    private static func promptText(_ message: ChatMessage) -> String? {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        let files = message.parts.compactMap { $0["filename"]?.string }
        return files.isEmpty ? nil : files.joined(separator: ", ")
    }

    /// Oversight records start before their answer is stored: each goes to the first unpaired
    /// answer stored at or after it (the web app's pairing).
    private static func pairCosts(_ costs: [TraceTurnCost], answers: [ChatMessage]) -> [String: Double] {
        let rows = costs.compactMap { c in TraceDate.parse(c.created_at).map { (c, $0) } }.sorted { $0.1 < $1.1 }
        let dated = answers.compactMap { m in m.meta?["created_at"]?.string.flatMap(TraceDate.parse).map { (m.id, $0) } }
        var result: [String: Double] = [:]
        var next = 0
        for (row, start) in rows {
            while next < dated.count && dated[next].1 < start { next += 1 }
            guard next < dated.count else { break }
            if let cost = row.cost { result[dated[next].0] = cost }
            next += 1
        }
        return result
    }
}

/// The backend sends both `…T20:21:50.543Z` and `…T20:22:14.217183+00:00`.
enum TraceDate {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func parse(_ string: String) -> Date? {
        if let d = fractional.date(from: string) ?? plain.date(from: string) { return d }
        // Trim microseconds to milliseconds: "…:14.217183+00:00" → "…:14.217+00:00".
        guard let dot = string.firstIndex(of: ".") else { return nil }
        let digits = string[string.index(after: dot)...].prefix { $0.isNumber }
        let trimmed = string[..<dot] + "." + digits.prefix(3) + string[digits.endIndex...]
        return fractional.date(from: String(trimmed))
    }
}

enum TraceFormat {
    static func duration(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        if ms < 1 { return "<1 ms" }
        if ms < 1000 { return "\(Int(ms.rounded())) ms" }
        if ms < 60_000 { return String(format: ms < 10_000 ? "%.2f s" : "%.1f s", ms / 1000) }
        let s = Int((ms / 1000).rounded())
        return "\(s / 60) m \(s % 60) s"
    }

    static func tokens(_ n: Int?) -> String {
        guard let n else { return "—" }
        return n.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    static func cost(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value == 0 { return "$0" }
        if value < 0.01 { return "$" + String(format: "%.4f", value) }
        return value.formatted(.currency(code: "USD"))
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
    }
}
