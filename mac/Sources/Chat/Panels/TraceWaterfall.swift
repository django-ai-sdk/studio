import SwiftUI

struct TraceTurnCard: View {
    let turn: TraceTurn
    let layout: TraceLayout
    @Binding var selected: String?
    @Binding var collapsedSpans: Set<String>
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded {
                Divider()
                TraceAxis(total: turn.durationMs, layout: layout)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(rows, id: \.id) { node in
                        TraceSpanRow(
                            node: node, layout: layout,
                            isSelected: selected == node.id,
                            isCollapsed: collapsedSpans.contains(node.id),
                            toggle: { toggle(node.id) },
                            select: { withAnimation(.snappy(duration: 0.2)) { selected = selected == node.id ? nil : node.id } }
                        )
                        if selected == node.id {
                            TraceSpanDetail(node: node, layout: layout)
                                .padding(.leading, layout.wide ? CGFloat(min(node.depth, layout.maxIndentDepth)) * layout.indent + 22 : 4)
                                .padding(.vertical, 4)
                                .transition(.opacity)
                        }
                    }
                }
            }
        }
        .padding(layout.wide ? 14 : 10)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(turn.errorCount > 0 ? AnyShapeStyle(.red.opacity(0.45)) : AnyShapeStyle(.separator), lineWidth: 1)
        }
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(turn.title).font(.headline)
                    if turn.errorCount > 0 {
                        Label("\(turn.errorCount)", systemImage: "exclamationmark.octagon.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                            .help("\(turn.errorCount) span\(turn.errorCount == 1 ? "" : "s") failed")
                    }
                    Spacer(minLength: 4)
                    Text(TraceFormat.duration(turn.durationMs))
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let prompt = turn.prompt {
                    Text(prompt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(layout.wide ? 1 : 2)
                        .padding(.leading, 18)
                }
                metadata.padding(.leading, 18)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(turn.title), \(TraceFormat.duration(turn.durationMs))")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint(turn.prompt ?? "")
    }

    private var metadata: some View {
        let items: [(String, String, String?)] = [
            turn.models.first.map { ("cpu", turn.models.count > 1 ? "\($0) +\(turn.models.count - 1)" : $0, turn.models.joined(separator: ", ")) },
            turn.tokens.map { ("number", "\(TraceFormat.tokens($0)) tokens", tokenHelp) },
            turn.cost.map { ("dollarsign.circle", TraceFormat.cost($0), nil) },
            ("point.3.connected.trianglepath.dotted", "\(turn.spanCount) spans", nil),
        ].compactMap { $0 }
        return TraceFlow(spacing: 10, lineSpacing: 2) {
            ForEach(items, id: \.1) { icon, text, help in
                Label(text, systemImage: icon)
                    .labelStyle(TraceCompactLabelStyle())
                    .help(help ?? "")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var tokenHelp: String? {
        guard let p = turn.promptTokens, let c = turn.completionTokens else { return nil }
        return "\(p.formatted()) prompt · \(c.formatted()) completion"
    }

    private var rows: [TraceNode] {
        var out: [TraceNode] = []
        func walk(_ nodes: [TraceNode]) {
            for node in nodes {
                out.append(node)
                if !collapsedSpans.contains(node.id) { walk(node.children) }
            }
        }
        walk(turn.roots)
        return out
    }

    private func toggle(_ id: String) {
        withAnimation(.snappy(duration: 0.2)) {
            if collapsedSpans.contains(id) { collapsedSpans.remove(id) } else { collapsedSpans.insert(id) }
        }
    }
}

private struct TraceAxis: View {
    let total: Double
    let layout: TraceLayout

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Text("0")
                ForEach(layout.wide ? [0.25, 0.5, 0.75] : [], id: \.self) { f in
                    Spacer(minLength: 2)
                    Text(TraceFormat.duration(total * f))
                }
                Spacer(minLength: 2)
                Text(TraceFormat.duration(total))
            }
            .lineLimit(1)
            .frame(width: layout.track)
        }
        .font(.caption2)
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
        .accessibilityHidden(true)
    }
}

struct TraceSpanRow: View {
    let node: TraceNode
    let layout: TraceLayout
    let isSelected: Bool
    let isCollapsed: Bool
    let toggle: () -> Void
    let select: () -> Void
    @State private var hovering = false

    private var color: Color { node.error != nil ? .red : node.kind.color }

    var body: some View {
        HStack(spacing: layout.wide ? 6 : 4) {
            Color.clear.frame(width: CGFloat(min(node.depth, layout.maxIndentDepth)) * layout.indent, height: 1)
            if node.children.isEmpty {
                Color.clear.frame(width: 12, height: 1)
            } else {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 12, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(isCollapsed ? "Expand \(node.title)" : "Collapse \(node.title)")
            }
            Button(action: select) {
                HStack(spacing: layout.wide ? 6 : 4) {
                    icon.frame(width: 16)
                    Text(node.title)
                        .foregroundStyle(node.error != nil ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if let detail = node.detail, layout.wide || node.kind == .llm && layout.width > 420 {
                        Text(detail).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if layout.wide {
                        Text(node.span.total_tokens.map { "\(TraceFormat.tokens($0)) tok" } ?? "")
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                    Text(node.isRunning ? "running" : TraceFormat.duration(node.durationMs))
                        .foregroundStyle(.secondary)
                        .frame(width: layout.wide ? 64 : 50, alignment: .trailing)
                    TraceBar(node: node, color: color)
                        .frame(width: layout.track, height: layout.wide ? 8 : 6)
                }
                .monospacedDigit()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(node.kind.label): \(node.title)")
            .accessibilityValue([node.error.map { "Failed: \($0)" }, TraceFormat.duration(node.durationMs),
                                 node.model, node.span.total_tokens.map { "\($0) tokens" }].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint("Shows span details")
        }
        .font(.callout)
        .padding(.horizontal, layout.wide ? 6 : 4)
        .padding(.vertical, 3)
        .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .help(node.error ?? node.span.operation_name)
    }

    @ViewBuilder private var icon: some View {
        if node.error != nil {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
        } else if node.isRunning {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: node.kind.systemImage).foregroundStyle(node.kind.color)
        }
    }

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.tint.opacity(0.16)) }
        if node.error != nil { return AnyShapeStyle(.red.opacity(hovering ? 0.12 : 0.06)) }
        return hovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear)
    }
}

private struct TraceBar: View {
    let node: TraceNode
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Capsule().fill(.quaternary.opacity(0.5))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(3, w * node.width))
                        .offset(x: min(w * node.offset, w - 3))
                        .opacity(node.isRunning ? 0.6 : 1)
                }
        }
        .accessibilityHidden(true)
    }
}

extension TraceSpanKind {
    var color: Color {
        switch self {
        case .llm: .purple
        case .tool: .orange
        case .retrieval: .teal
        case .subagent: .indigo
        case .agent: .blue
        case .pipeline, .component: .cyan
        case .step, .hook, .other: .gray
        }
    }
}

struct TraceCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

struct TraceFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth { y += line + lineSpacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
