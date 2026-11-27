import SwiftUI

/// One collapsible timeline above the answer with everything the agent did first: reasoning and
/// every tool call, in stream order (web: ChainOfThought.tsx). While streaming, the header names
/// the step in flight with a shimmer; when done it reads "Thought for 4s · Used 2 tools".
struct ChainOfThoughtView: View {
    let messageID: String
    /// Reasoning parts (with their index in `message.parts`, for timing) and tool parts.
    let steps: [(index: Int, part: JSON)]
    let streaming: Bool
    @State private var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(messageID: String, steps: [(index: Int, part: JSON)], streaming: Bool, expanded: Bool = false) {
        self.messageID = messageID
        self.steps = steps
        self.streaming = streaming
        _expanded = State(initialValue: expanded)
    }

    private var running: Bool { streaming && steps.contains { Part.isRunning($0.part) } }
    private var toolCount: Int { steps.filter { Part.isTool($0.part) }.count }
    private var hasReasoning: Bool { steps.contains { Part.type($0.part) == "reasoning" } }

    private var label: String {
        if running {
            if let active = steps.last(where: { Part.isRunning($0.part) }), Part.isTool(active.part) {
                return Part.humanize(Part.toolName(active.part)) + "…"
            }
            return "Thinking…"
        }
        var segments: [String] = []
        if hasReasoning {
            if let seconds = StreamScratch.shared.thinkingDuration(messageID), seconds >= 0.5 {
                segments.append("Thought for \(Self.duration(seconds))")
            } else {
                segments.append("Thought")
            }
        }
        if toolCount == 1 { segments.append("Used 1 tool") } else if toolCount > 1 { segments.append("Used \(toolCount) tools") }
        return segments.isEmpty ? "Steps" : segments.joined(separator: " · ")
    }

    /// The end of the reasoning being streamed, flattened to one line.
    private var liveTail: String? {
        guard let active = steps.last(where: { Part.isRunning($0.part) }), Part.type(active.part) == "reasoning",
              let text = active.part["text"]?.string, !text.isEmpty else { return nil }
        let flat = text.suffix(160).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.isEmpty ? nil : flat
    }

    static func duration(_ s: TimeInterval) -> String {
        s < 60 ? "\(Int(s.rounded()))s" : "\(Int(s) / 60)m \(Int(s) % 60)s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Group {
                        if running {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: hasReasoning ? "sparkles" : "wrench.and.screwdriver")
                        }
                    }
                    .frame(width: 14, height: 14)
                    Text(label)
                        .shimmer(active: running)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows the reasoning and tool calls")

            if running, !expanded, let tail = liveTail {
                // The thought in flight, as a faint two-line ticker under the header.
                Text(tail)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.leading, 20)
                    .accessibilityHidden(true)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    // Keyed by tool call / part index, so a row's expansion stays put while steps stream in.
                    ForEach(steps.map { KeyedStep(step: $0) }, id: \.id) { keyed in
                        let step = keyed.step
                        if Part.isTool(step.part) {
                            ToolCallRow(part: step.part)
                        } else {
                            ReasoningStep(part: step.part, duration: StreamScratch.shared.thinkingDuration(messageID, part: step.index))
                        }
                    }
                }
                .padding(.leading, 7)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.separator).frame(width: 1)
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A step keyed by its tool call id (else its part index), stable as parts stream in.
private struct KeyedStep {
    let step: (index: Int, part: JSON)
    var id: String { step.part["toolCallId"]?.string ?? "part-\(step.index)" }
}

/// One reasoning block inside the chain: a one-line preview that expands to the full text.
private struct ReasoningStep: View {
    let part: JSON
    let duration: TimeInterval?
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: String { part["text"]?.string ?? part["reasoning"]?.string ?? "" }
    private var streaming: Bool { Part.isRunning(part) }

    private var preview: String {
        let flat = text.prefix(400).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if flat.isEmpty { return "…" }
        return flat.count > 90 ? String(flat.prefix(90)) + "…" : flat
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(streaming ? "Reasoning…" : preview)
                        .shimmer(active: streaming)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let duration, !streaming {
                        Text(ChainOfThoughtView.duration(duration)).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(streaming ? "Reasoning" : "Reasoning: \(preview)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded || (streaming && !text.isEmpty) {
                MarkdownText(markdown: text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
        }
    }
}

// MARK: Shimmer

extension View {
    /// A light sweep across the view while `active` (static with Reduce Motion).
    func shimmer(active: Bool) -> some View { modifier(Shimmer(active: active)) }
}

private struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                content.mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.45), location: 0),
                            .init(color: .black.opacity(0.45), location: max(0, phase - 0.2)),
                            .init(color: .black, location: phase),
                            .init(color: .black.opacity(0.45), location: min(1, phase + 0.2)),
                            .init(color: .black.opacity(0.45), location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing)
                }
            }
        } else {
            content
        }
    }
}
