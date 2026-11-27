import SwiftUI

struct OversightCheckDetail: View {
    let item: OversightCheck

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch item {
                case .rule(let match, let reviews): RuleDetail(match: match, reviews: reviews)
                case .lens(let answer): LensDetail(answer: answer)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 340)
        .frame(maxHeight: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DetailHeader: View {
    let kind: String
    let stage: String
    let title: String
    let code: String
    let tone: OversightTone

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(kind) · \(OversightStageInfo.of(stage).title)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(code).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            OversightBadge(tone: tone)
        }
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            content
        }
    }
}

private struct Fact: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ConditionView: View {
    let condition: OversightCondition

    var body: some View {
        switch condition {
        case .text(let text):
            Fact(text: text)
        case .not(let inner):
            nested(label: "None of this:", [inner])
        case .group(let all, let items):
            nested(label: all ? "All of these:" : "Any of these:", items)
        }
    }

    private func nested(label: String, _ items: [OversightCondition]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, child in ConditionView(condition: child) }
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 2) }
        }
    }
}

private struct RuleDetail: View {
    let match: OversightMatch
    let reviews: [OversightReview]

    var body: some View {
        let mode = OversightTone.mode(match.mode)
        DetailHeader(kind: "Rule", stage: match.stage, title: OversightFormat.label(match.rule), code: match.rule,
                     tone: .match(match, reviewed: !reviews.isEmpty))

        Text(sentence)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

        DetailSection(title: "When") {
            ConditionView(condition: .describe(match.condition))
        }

        DetailSection(title: match.acted ? "Then" : "Would Have") {
            let actions = match.actions ?? []
            if actions.isEmpty {
                Text("Only records the match.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Fact(text: OversightAction.describe(action, stage: match.stage))
                }
            }
            if match.stage == "reflect" {
                Text("This runs after the turn is recorded, so it can only record and alert; it cannot change the answer.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        DetailSection(title: "Mode") {
            Label {
                Text(mode.label)
            } icon: {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(mode.color)
            }
            .font(.callout)
        }

        if !reviews.isEmpty {
            DetailSection(title: "Review") {
                ForEach(reviews) { review in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(OversightFormat.label(review.queue)) queue · \(review.status == "open" ? "waiting" : OversightFormat.humanize(review.status))")
                            .font(.callout)
                        if let agree = review.agree {
                            Text(agree ? "The reviewer agreed with the rule." : "The reviewer disagreed with the rule.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let note = review.note, !note.isEmpty {
                            Text("“\(note)”").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        if let at = match.created_at, !at.isEmpty {
            Text("Matched \(OversightFormat.when(at))").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var sentence: String {
        switch (match.mode, match.acted) {
        case (_, true): "Its condition held and it acted on this turn."
        case ("report", _): "Report only: its condition held, so it recorded what it would have done."
        default: "Its condition held; it recorded the match without acting."
        }
    }
}

private struct LensDetail: View {
    let answer: OversightAnswer

    var body: some View {
        let tone = OversightTone.answer(answer)
        let name = answer.label.flatMap { $0.isEmpty ? nil : $0 } ?? answer.lens
        DetailHeader(kind: "Lens", stage: answer.stage, title: OversightFormat.label(name), code: answer.lens, tone: tone)

        if let error = answer.error, !error.isEmpty {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        DetailSection(title: "Answer") {
            HStack(alignment: .firstTextBaseline) {
                Text(OversightFormat.value(answer.value))
                    .font(.title3.weight(.medium))
                    .foregroundStyle(tone.color)
                    .textSelection(.enabled)
                Spacer()
                if let kind = answer.kind, !kind.isEmpty {
                    Text(OversightFormat.label(kind)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if case .number(let score)? = answer.value {
                Gauge(value: min(max(score, 0), 1)) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(tone.color)
                    .accessibilityLabel("Score \(OversightFormat.percent(score))")
            }
            if let confidence = answer.confidence {
                HStack {
                    Text("Confidence").foregroundStyle(.secondary)
                    Spacer()
                    Text(OversightFormat.percent(confidence)).monospacedDigit()
                }
                .font(.callout)
            }
        }

        if let rationale = answer.rationale, !rationale.isEmpty {
            DetailSection(title: "Why") {
                Text(rationale)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let spans = answer.spans, !spans.isEmpty {
            DetailSection(title: "Found") {
                FlowLayout(spacing: 6) {
                    ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                        let label = span["label"]?.string.map(OversightFormat.humanize) ?? "match"
                        let text = span["text"]?.string
                        OversightBadge(tone: .init(label: text.map { "\(label): \($0)" } ?? label,
                                                   symbol: "smallcircle.filled.circle", color: .orange), showsIcon: false)
                    }
                }
            }
        }

        if let items = answer.items, !items.isEmpty {
            DetailSection(title: "Scores") {
                ForEach(items.sorted { $0.value > $1.value }, id: \.key) { key, value in
                    HStack {
                        Text(OversightFormat.label(key)).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        Gauge(value: min(max(value, 0), 1)) { EmptyView() }
                            .gaugeStyle(.accessoryLinearCapacity)
                            .frame(width: 90)
                        Text(OversightFormat.percent(value)).font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }

        DetailSection(title: "Answered By") {
            VStack(alignment: .leading, spacing: 4) {
                step(answerer: answer.answerer, model: answer.model, value: answer.value,
                     confidence: answer.confidence, latency: answer.latency_ms, error: answer.error, final: true)
                if let trail = answer.trail, !trail.isEmpty {
                    Text("Asked first").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(Array(trail.enumerated()), id: \.offset) { _, s in
                        step(answerer: s["answerer"]?.string ?? "?", model: s["model"]?.string, value: s["value"],
                             confidence: s["confidence"]?.number, latency: s["latency_ms"]?.number,
                             error: s["error"]?.string, final: false)
                    }
                }
            }
        }

        if let cost = answer.cost {
            Text("Cost \(cost.formatted(.currency(code: "USD").precision(.fractionLength(2...5))))")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func step(answerer: String, model: String?, value: JSON?, confidence: Double?, latency: Double?,
                      error: String?, final: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: final ? "checkmark.seal" : "arrow.turn.down.right")
                .foregroundStyle(final ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(OversightFormat.label(answerer)).font(.callout)
                let meta = [model.flatMap { $0.isEmpty ? nil : $0 },
                            error.flatMap { $0.isEmpty ? nil : "error: \($0)" } ?? "said \(OversightFormat.value(value))",
                            confidence.map { "\(OversightFormat.percent($0)) sure" },
                            latency.map(OversightFormat.seconds)].compactMap { $0 }
                Text(meta.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
