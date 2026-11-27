import SwiftUI

struct TraceSpanDetail: View {
    let node: TraceNode
    let layout: TraceLayout

    private var span: TraceSpanOut { node.span }
    private var sections: (input: JSON?, output: JSON?, attributes: JSON?) { TraceBuilder.sections(span) }

    var body: some View {
        let sections = sections
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: node.error != nil ? "exclamationmark.octagon.fill" : node.kind.systemImage)
                    .foregroundStyle(node.error != nil ? .red : node.kind.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.title).font(.headline)
                    Text(span.operation_name)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 4)
                Text(node.kind.label)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(node.kind.color.opacity(0.15), in: Capsule())
                    .foregroundStyle(node.kind.color)
            }

            if let error = node.error {
                Label {
                    Text(error).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(.red)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            facts

            if let input = sections.input { TraceCodeSection(title: "Input", json: input) }
            if let output = sections.output { TraceCodeSection(title: "Output", json: output) }
            if let attributes = sections.attributes { TraceCodeSection(title: "Attributes", json: attributes) }
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var facts: some View {
        let rows: [(String, String)] = [
            ("Started", TraceFormat.time(node.start)),
            node.end.map { ("Ended", TraceFormat.time($0)) },
            ("Duration", node.isRunning ? "Running" : TraceFormat.duration(node.durationMs)),
            span.agent_name.flatMap { $0.isEmpty ? nil : ("Agent", $0) },
            node.model.map { ("Model", $0) },
            span.prompt_tokens.map { ("Prompt tokens", $0.formatted()) },
            span.completion_tokens.map { ("Completion tokens", $0.formatted()) },
            span.total_tokens.map { ("Total tokens", $0.formatted()) },
        ].compactMap { $0 }
        let columns = layout.wide ? 2 : 1
        let perColumn = Int((Double(rows.count) / Double(columns)).rounded(.up))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 24) {
                ForEach(0..<columns, id: \.self) { c in
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                        ForEach(Array(rows.dropFirst(c * perColumn).prefix(perColumn)), id: \.0) { label, value in
                            GridRow {
                                Text(label).foregroundStyle(.secondary)
                                Text(value).monospacedDigit().textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("ID").foregroundStyle(.secondary)
                Text(span.id).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button {
                    Platform.copy(span.id)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy Span ID")
                    .accessibilityLabel("Copy span ID")
            }
        }
        .font(.callout)
    }
}

private struct TraceCodeSection: View {
    let title: String
    let json: JSON

    private var text: String { json.string ?? json.pretty }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.topLeading)
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
            .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    Platform.copy(text)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .help("Copy \(title)")
                    .accessibilityLabel("Copy \(title.lowercased())")
            }
        }
    }
}
