import SwiftUI

struct ToolCallRow: View {
    let part: JSON
    @State private var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(part: JSON, expanded: Bool = false) {
        self.part = part
        _expanded = State(initialValue: expanded)
    }

    private var name: String { Part.toolName(part) }
    private var title: String { Part.humanize(name) }
    private var error: String? { Part.toolError(part) }
    private var running: Bool { Part.isRunning(part) && error == nil }
    private var marks: (agent: String?, handoff: String?) { Part.agentMarks(part) }

    private var subtitle: String? {
        if let handoff = marks.handoff { return handoff.caseInsensitiveCompare(title) == .orderedSame ? "Handoff" : "Handed off to \(handoff)" }
        if let agent = marks.agent { return "by \(agent)" }
        return nil
    }

    private var stateDescription: String {
        if let error { return "Failed: \(error)" }
        if part["state"]?.string == "output-denied" { return "Denied" }
        return running ? "Running" : "Done"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(for: name, handoff: marks.handoff != nil))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(title)
                        .foregroundStyle(.primary)
                        .shimmer(active: running)
                    if let subtitle {
                        Text(subtitle).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    stateIcon
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .padding(.leading, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title) tool\(subtitle.map { ", \($0)" } ?? "")")
            .accessibilityValue("\(stateDescription), \(expanded ? "expanded" : "collapsed")")
            .accessibilityHint("Shows the tool's input and output")

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let input = part["input"], input != .null, input.object?.isEmpty != true {
                        ToolSection(title: "Input") { JSONBlock(json: input) }
                    }
                    if let error {
                        ToolSection(title: "Error") {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    } else if let result = Part.toolResult(part) {
                        ToolSection(title: "Output") {
                            if let text = result.string {
                                MarkdownText(markdown: text).font(.callout)
                                    .padding(10)
                                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            } else {
                                JSONBlock(json: result)
                            }
                        }
                    } else if running {
                        Text("Running…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 28)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var stateIcon: some View {
        if error != nil {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else if part["state"]?.string == "output-denied" {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        } else if running {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    static func symbol(for name: String, handoff: Bool) -> String {
        let n = name.lowercased()
        if handoff { return "person.2.wave.2" }
        if n.hasPrefix("artifact_") { return "square.on.square" }
        if n.contains("search") || n.contains("lookup") || n.contains("find") { return n.contains("web") ? "globe" : "magnifyingglass" }
        if n.contains("web") || n.contains("url") || n.contains("fetch") || n.contains("browse") { return "globe" }
        if n.contains("weather") { return "cloud.sun" }
        if n.contains("file") || n.contains("document") { return "doc.text" }
        if n.contains("memory") || n.contains("remember") { return "brain.head.profile" }
        if n.contains("code") || n.contains("python") || n.contains("exec") || n.contains("run") { return "chevron.left.forwardslash.chevron.right" }
        if n.contains("mail") { return "envelope" }
        if n.contains("calendar") || n.contains("date") || n.contains("time") { return "calendar" }
        if n.contains("agent") || n.contains("planner") || n.contains("delegate") { return "person.2" }
        return "wrench.and.screwdriver"
    }
}

private struct ToolSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

struct JSONBlock: View {
    let json: JSON

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(json.pretty)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize()
                .padding(10)
        }
        .defaultScrollAnchor(.topLeading)
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button { Pasteboard.copy(json.pretty) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .chatPartHitTarget()
                .padding(6)
                .help("Copy JSON")
                .accessibilityLabel("Copy JSON")
        }
    }
}
