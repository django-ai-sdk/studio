import SwiftUI

// MARK: Oversight

/// One banner per thing the user should know about oversight (web: OversightNotice.tsx).
struct OversightBanners: View {
    let lines: [Oversight.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Offsets: lines can repeat and rows hold no state.
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let style = Self.style(line.kind)
                Label {
                    Text(line.text).textSelection(.enabled)
                } icon: {
                    Image(systemName: style.symbol).foregroundStyle(style.color)
                }
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(style.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Oversight: \(line.text)")
            }
        }
    }

    static func style(_ kind: String) -> (symbol: String, color: Color) {
        switch kind {
        case "notice": ("bell.badge", .accentColor)
        case "block": ("nosign", .red)
        case "mask": ("eye.slash", .orange)
        default: ("checkmark.shield", .secondary)
        }
    }
}

// MARK: Errors

/// Inline error callout for `data-error` / `error` parts and `finish_reason == "error"`.
struct ErrorCallout: View {
    let message: String
    var reference: String?
    var retryable = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(message).foregroundStyle(.primary)
                if retryable || reference != nil {
                    Text([retryable ? "You can try again." : nil, reference.map { "Reference: \($0)" }]
                        .compactMap { $0 }.joined(separator: " "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.red.opacity(0.25)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }
}

// MARK: Sources (source-url / source-document parts)

nonisolated struct SourceItem: Identifiable, Hashable {
    let id: String
    let number: Int
    let title: String
    let url: URL?
    let isDocument: Bool
}

/// Numbered source chips under the answer.
struct SourcesRow: View {
    let sources: [SourceItem]
    @Environment(\.openURL) private var openURL

    var body: some View {
        FlowLayout(spacing: 6) {
            Label("Sources", systemImage: "books.vertical")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            ForEach(sources) { source in
                Button {
                    if let url = source.url { openURL(url) }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(source.number)").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        Image(systemName: source.isDocument ? "doc.text" : "globe").font(.caption2)
                        Text(source.title).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(maxWidth: 240)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(source.url == nil)
                .webLinkMenu(source.url)
                .help(source.url?.absoluteString ?? source.title)
                .accessibilityLabel("Source \(source.number): \(source.title)")
            }
        }
    }
}

private extension View {
    /// Open Link / Open in Default Browser / Copy Link on right-click, for http(s) links only.
    @ViewBuilder func webLinkMenu(_ url: URL?) -> some View {
        if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            contextMenu { WebLinkMenu(url: url) }
        } else {
            self
        }
    }
}

// MARK: Citations (citations artifact)

/// What the citations sheet shows: one citation's evidence, or the cited sources.
nonisolated enum CitationFocus: Identifiable, Hashable {
    case citation(Int)
    case all
    var id: String { switch self { case .citation(let i): "c\(i)"; case .all: "all" } }
}

/// Sheet with the sources supporting a cited passage (web: the sources sheet).
struct CitationsSheet: View {
    let data: Citations
    let focus: CitationFocus
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                if case .citation(let i) = focus, let c = data.citations.first(where: { $0.index == i }) {
                    Section("Cited passage") {
                        Text("“\(c.quote)”").italic().textSelection(.enabled)
                    }
                    ForEach(Array(c.evidence.enumerated()), id: \.offset) { _, e in
                        if let source = data.source(e.key) {
                            Section {
                                SourceCard(source: source, passage: e.text)
                            }
                        }
                    }
                } else {
                    ForEach(data.citedSources.isEmpty ? data.sources : data.citedSources) { source in
                        Section { SourceCard(source: source, passage: nil) }
                    }
                }
            }
            .navigationTitle(focus == .all ? "Sources" : "Source")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .macSheetFrame(minWidth: 520, idealWidth: 640, minHeight: 360, idealHeight: 520)
    }
}

private struct SourceCard: View {
    let source: Citations.Source
    let passage: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if source.number > 0 {
                    Text("\(source.number)")
                        .font(.caption.weight(.bold))
                        .frame(width: 20, height: 20)
                        .background(.tint.opacity(0.15), in: Circle())
                }
                Image(systemName: source.kind == "web" ? "globe" : "doc.text").foregroundStyle(.secondary)
                Text(source.title).font(.headline).lineLimit(2)
                Spacer()
                if let url = source.url {
                    Button { openURL(url) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless)
                        .webLinkMenu(url)
                        .chatPartHitTarget()
                        .help(url.absoluteString)
                        .accessibilityLabel("Open source")
                }
            }
            let text = passage.flatMap { $0.isEmpty ? nil : $0 } ?? String(source.content.prefix(600))
            if !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(.tint.opacity(0.5)).frame(width: 2) }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: Typing indicator

/// Three pulsing dots while the reply has no content yet.
struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    let phase = reduceMotion ? 0.5 : (sin((t * 2 * .pi / 1.2) - Double(i) * 0.7) + 1) / 2
                    Circle()
                        .fill(.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.65 * phase)
                        .scaleEffect(0.8 + 0.25 * phase)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement()
        .accessibilityLabel("Assistant is typing")
    }
}

// MARK: Suggestions

/// Follow-up suggestions (`data-suggestions`): tapping one sends it.
struct SuggestionChips: View {
    let suggestions: [String]
    let send: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Offsets: suggestions can repeat and rows hold no state.
            ForEach(Array(suggestions.enumerated()), id: \.offset) { _, s in
                Button { send(s) } label: {
                    Label(s, systemImage: "arrow.turn.down.right")
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .help("Ask this")
                .accessibilityHint("Sends this as your next message")
            }
        }
    }
}

// MARK: Flow layout

/// Wraps children onto new lines, like CSS `flex-wrap`.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                                  proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let y = rows[rows.count - 1].y + rows[rows.count - 1].height + spacing
                rows.append(Row(y: y))
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
