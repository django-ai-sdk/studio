import SwiftUI

struct OversightBadge: View {
    let tone: OversightTone
    var showsIcon = true
    var maxLength = 40

    private var text: String { tone.label.count > maxLength ? tone.label.prefix(maxLength - 1) + "…" : tone.label }

    var body: some View {
        HStack(spacing: 3) {
            if showsIcon { Image(systemName: tone.symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .help(tone.label)
        .font(.caption.weight(.medium))
        .foregroundStyle(tone.color)
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(tone.color.opacity(0.13), in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct OversightCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.8)))
    }
}

extension View {
    func oversightCard() -> some View { modifier(OversightCardBackground()) }
}

struct OversightTurnCard: View {
    let row: OversightTurn
    let number: Int?
    let detail: OversightTurn?
    let detailError: String?
    @Binding var isExpanded: Bool
    let loadDetail: () async -> Void
    let retryDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                header.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the checks" : "Shows the checks")

            if isExpanded {
                Divider().padding(.horizontal, 12)
                Group {
                    if let detail {
                        OversightTurnBody(turn: detail)
                    } else if let detailError {
                        HStack {
                            Label("Couldn’t load the checks.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                                .help(detailError)
                            Spacer()
                            Button("Try Again", action: retryDetail).controlSize(.small)
                        }
                        .font(.callout)
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }
                .padding(12)
                .transition(.opacity)
                .task { await loadDetail() }
            }
        }
        .oversightCard()
    }

    private var title: String { number.map { "Turn \($0)" } ?? "Turn" }

    private var meta: String {
        let turn = detail ?? row
        return [
            OversightFormat.time(turn.created_at),
            turn.policy.flatMap { $0.isEmpty ? nil : "\($0) policy" },
            turn.latency_ms.map(OversightFormat.seconds),
            turn.closed ? summary(turn) : nil,
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func summary(_ turn: OversightTurn) -> String {
        let reviews = turn.reviews_open ?? 0
        if reviews > 0 { return reviews == 1 ? "sent to review" : "\(reviews) sent to review" }
        let matches = turn.matches ?? []
        if let acted = OversightStage.actedLabel(matches) { return acted }
        if !matches.isEmpty { return OversightFormat.plural(matches.count, "rule reported", "rules reported") }
        return "passed"
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.headline)
                    if let preview = (detail ?? row).preview, !preview.isEmpty {
                        Text(preview)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            OversightBadge(tone: .turn(detail ?? row))
                .layoutPriority(1)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

struct OversightTurnBody: View {
    let turn: OversightTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if hasOutcomeExtras { outcomeRow }
            OversightNotices(turn: turn)
            OversightPipelineView(turn: turn)
            OversightTurnFacts(turn: turn)
        }
    }

    private var hasOutcomeExtras: Bool {
        (turn.report_outcome.map { !$0.isEmpty && $0 != turn.outcome } ?? false) || !(turn.severity ?? "").isEmpty
    }

    private var outcomeRow: some View {
        FlowLayout(spacing: 6) {
            if let report = turn.report_outcome, !report.isEmpty, report != turn.outcome {
                OversightBadge(tone: .init(label: "Report: \(OversightTone.outcome(report).label)",
                                           symbol: "doc.text.magnifyingglass", color: .secondary))
                    .help("What report-only rules would have done")
            }
            if let severity = turn.severity, !severity.isEmpty {
                OversightBadge(tone: .init(label: "Severity \(severity)", symbol: "exclamationmark.triangle",
                                           color: severity == "high" || severity == "critical" ? .red : .orange))
            }
        }
    }
}

struct OversightNotices: View {
    let turn: OversightTurn

    var body: some View {
        let lines = Self.lines(turn)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.text) { line in
                    Label {
                        Text(line.text).textSelection(.enabled)
                    } icon: {
                        Image(systemName: line.symbol).foregroundStyle(line.color)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(line.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    struct Line { let symbol: String; let color: Color; let text: String }

    static func lines(_ turn: OversightTurn) -> [Line] {
        var lines: [Line] = []
        let acted = (turn.matches ?? []).filter(\.acted)
        for m in acted {
            for action in m.actions ?? [] where action["kind"]?.string == "block" {
                if let message = action["message"]?.string, !message.isEmpty {
                    lines.append(Line(symbol: "nosign", color: .red, text: "The user was told: “\(message)”"))
                }
            }
        }
        var teams: [String] = []
        for action in acted.flatMap({ $0.actions ?? [] }) where action["kind"]?.string == "notify" {
            for team in (action["to"]?.array ?? []).compactMap(\.string) where !teams.contains(team) { teams.append(team) }
        }
        for team in teams {
            lines.append(Line(symbol: "bell.badge", color: .blue,
                              text: "\(OversightFormat.label(team)) was alerted\(turn.severity.flatMap { $0.isEmpty ? nil : ", severity \($0)" } ?? "")."))
        }
        let open = (turn.reviews ?? []).filter { $0.status == "open" }
        if !open.isEmpty {
            let queues = OversightFormat.list(Array(Set(open.map { OversightFormat.humanize($0.queue) })).sorted())
            lines.append(Line(symbol: "person.badge.clock", color: .purple,
                              text: open.count == 1 ? "Waiting for review in \(queues)." : "\(open.count) reviews waiting in \(queues)."))
        }
        if let error = turn.error, !error.isEmpty {
            lines.append(Line(symbol: "exclamationmark.triangle.fill", color: .red, text: "Error: \(error)"))
        }
        return lines
    }
}

struct OversightTurnFacts: View {
    let turn: OversightTurn
    @State private var showsContent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let facts = self.facts
            if !facts.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(facts, id: \.0) { name, value in
                        GridRow {
                            Text(name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        }
                    }
                }
                .font(.caption)
            }
            DisclosureGroup("Question and Answer", isExpanded: $showsContent) {
                content.padding(.top, 6)
            }
            .font(.callout)
        }
    }

    private var facts: [(String, String)] {
        var out: [(String, String)] = []
        if let a = turn.agent_name, !a.isEmpty { out.append(("Agent", a)) }
        if let c = turn.channel, !c.isEmpty { out.append(("Channel", c)) }
        if let m = turn.model, !m.isEmpty { out.append(("Model", m)) }
        if let t = turn.tokens { out.append(("Tokens", t.formatted())) }
        if let l = turn.latency_ms { out.append(("Latency", OversightFormat.seconds(l))) }
        if let c = turn.cost { out.append(("Cost", c.formatted(.currency(code: "USD").precision(.fractionLength(2...4))))) }
        return out
    }

    @ViewBuilder private var content: some View {
        if let content = turn.content, content != .null {
            VStack(alignment: .leading, spacing: 6) {
                block("Question", content["shown_input"]?.string ?? content["input"]?.string)
                block("Answer", content["shown_output"]?.string ?? content["output"]?.string)
            }
        } else {
            Text(Self.contentStates[turn.content_state ?? ""] ?? "No content to show.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func block(_ label: String, _ text: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(text.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                .font(.callout)
                .lineLimit(12)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    static let contentStates = [
        "withheld": "The question and answer are not shown to you.",
        "none": "No content was kept for this turn.",
        "expired": "The stored content has expired.",
        "unreadable": "The stored content can’t be opened here.",
    ]
}
