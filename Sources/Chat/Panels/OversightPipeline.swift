import SwiftUI

/// A turn's policy stages in run order as a vertical timeline, with the agent between
/// the gate and the tool calls (web: ProgressTracker in InsightsTab + OversightPipeline).
struct OversightPipelineView: View {
    let turn: OversightTurn

    var body: some View {
        let stages = OversightStage.stages(of: turn)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(stages) { stage in
                OversightStageRow(stage: stage, isLast: stage.id == stages.last?.id)
                if stage.id == "gate" { agentMarker(blocked: stage.matches.contains { $0.acted && $0.actionKinds.contains("block") }) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Oversight pipeline")
    }

    private func agentMarker(blocked: Bool) -> some View {
        TimelineRow(isLast: false) {
            Image(systemName: "cpu")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(blocked ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.background))
                .frame(width: 18, height: 18)
                .background(blocked ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.primary.opacity(0.85)),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        } content: {
            HStack(spacing: 4) {
                Text("Agent").font(.subheadline.weight(.medium))
                Text(blocked ? "· never saw the question" : "· thinks and answers")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .foregroundStyle(blocked ? .secondary : .primary)
            .padding(.bottom, 12)
        }
    }
}

/// A leading marker on a vertical line, then content.
private struct TimelineRow<Marker: View, Content: View>: View {
    let isLast: Bool
    @ViewBuilder let marker: Marker
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 28)
            .background(alignment: .topLeading) {
                if !isLast {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .padding(.top, 20)
                        .padding(.leading, 8.25)
                }
            }
            .overlay(alignment: .topLeading) { marker.padding(.top, 0.5) }
    }
}

struct OversightStageRow: View {
    let stage: OversightStage
    let isLast: Bool

    var body: some View {
        TimelineRow(isLast: isLast) {
            statusIcon
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(stage.info.title).font(.subheadline.weight(.semibold))
                        Text("· \(stage.info.name)").font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(stage.summary)
                        .font(.caption)
                        .foregroundStyle(stage.status == .failed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                }
                .help(stage.info.when)
                if !stage.matches.isEmpty || !stage.answers.isEmpty {
                    checks
                }
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(stage.info.title): \(stage.summary)")
    }

    private var statusIcon: some View {
        Group {
            switch stage.status {
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .red)
            case .running:
                ProgressView().controlSize(.mini)
            case .pending:
                Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 17))
        .frame(width: 18, height: 18)
        .background(Circle().fill(.background))
    }

    /// Rules first (what acted is what you came to see), then the lens answers.
    private var checks: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, 34) }
                OversightCheckRow(item: item)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var items: [OversightCheck] {
        stage.matches.map { m in .rule(m, stage.reviews.filter { $0.rule == m.rule }) } + stage.answers.map(OversightCheck.lens)
    }
}

/// A rule match or a lens answer, as listed under a stage and drilled into.
enum OversightCheck: Identifiable {
    case rule(OversightMatch, [OversightReview])
    case lens(OversightAnswer)

    var id: String {
        switch self {
        case .rule(let m, _): "rule:\(m.id)"
        case .lens(let a): "lens:\(a.id)"
        }
    }

    var title: String {
        switch self {
        case .rule(let m, _): OversightFormat.label(m.rule)
        case .lens(let a): OversightFormat.label(a.label.flatMap { $0.isEmpty ? nil : $0 } ?? a.lens)
        }
    }

    var tone: OversightTone {
        switch self {
        case .rule(let m, let reviews): .match(m, reviewed: !reviews.isEmpty)
        case .lens(let a): .answer(a)
        }
    }

    var meta: String {
        switch self {
        case .rule(let m, _):
            let kinds = m.actionKinds.map(OversightFormat.humanize)
            return "Rule · " + (kinds.isEmpty ? "\(m.mode) mode" : kinds.joined(separator: " · "))
        case .lens(let a):
            return [OversightFormat.humanize(a.answerer),
                    a.confidence.map { "\(OversightFormat.percent($0)) sure" },
                    a.latency_ms.map(OversightFormat.seconds)]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }
}

/// One check under a stage; click for its detail in a popover.
struct OversightCheckRow: View {
    let item: OversightCheck
    @State private var showsDetail = false
    @State private var hovering = false

    var body: some View {
        let tone = item.tone
        Button { showsDetail.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: tone.symbol)
                    .foregroundStyle(tone.color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.callout).lineLimit(2)
                    Text(item.meta).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                OversightBadge(tone: tone, showsIcon: false, maxLength: 16)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show details")
        .accessibilityLabel("\(item.title), \(tone.label). \(item.meta)")
        .accessibilityHint("Shows details")
        .popover(isPresented: $showsDetail, arrowEdge: .leading) {
            OversightCheckDetail(item: item)
        }
    }
}
