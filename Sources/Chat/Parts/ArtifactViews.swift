#if os(macOS)
import AppKit
#endif
import SwiftUI

/// An `artifact_*` tool call rendered natively (web: ArtifactRenderer.tsx): a card with the
/// artifact's kind and title, its content inline, and an "Open" button that shows it in a sheet.
struct ArtifactView: View {
    let part: JSON
    @State private var presented = false

    private var name: String { Part.toolName(part) }
    private var args: JSON { Part.artifactArgs(part) }
    private var kind: ArtifactKind { ArtifactKind(name) }
    private var title: String {
        args["title"]?.string ?? args["filename"]?.string ?? args["label"]?.string
            ?? args["command"]?.string.map { "$ \($0)" } ?? kind.label
    }

    var body: some View {
        if let error = Part.toolError(part) {
            Label("\(kind.label) failed: \(error)", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.red)
        } else if part["state"]?.string == "input-streaming" || (Part.isRunning(part) && args.object?.isEmpty != false) {
            ArtifactPlaceholder(kind: kind)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(kind.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if kind.opensInSheet {
                    Button("Open") { presented = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Open \(kind.label.lowercased()) in a larger view")
                }
            }
            .padding(12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(kind.label): \(title)")

            if kind.hasBody {
                Divider()
                ArtifactBody(name: name, part: part, args: args, compact: true)
                    .padding(12)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
        .sheet(isPresented: $presented) {
            ArtifactSheet(title: title, kind: kind) {
                ArtifactBody(name: name, part: part, args: args, compact: false)
            }
        }
    }
}

private struct ArtifactPlaceholder: View {
    let kind: ArtifactKind
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Creating \(kind.label.lowercased())…").foregroundStyle(.secondary).shimmer(active: true)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

private struct ArtifactSheet<Content: View>: View {
    let title: String
    let kind: ArtifactKind
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .macSheetFrame(minWidth: 560, idealWidth: 720, minHeight: 360, idealHeight: 560)
    }
}

struct ArtifactKind {
    let label: String
    let symbol: String
    var hasBody = true
    var opensInSheet = true

    init(_ name: String) {
        switch name {
        case "artifact_plan_artifact": (label, symbol) = ("Plan", "checklist")
        case "artifact_code_block_artifact": (label, symbol) = ("Code", "chevron.left.forwardslash.chevron.right")
        case "artifact_snippet_artifact": (label, symbol) = ("Snippet", "doc.on.clipboard")
        case "artifact_data_table_artifact": (label, symbol) = ("Table", "tablecells")
        case "artifact_document_artifact": (label, symbol, hasBody, opensInSheet) = ("Document", "doc.richtext", false, false)
        case "artifact_terminal_artifact": (label, symbol) = ("Terminal", "terminal")
        case "artifact_stack_trace_artifact": (label, symbol) = ("Stack Trace", "exclamationmark.triangle")
        case "artifact_image_artifact": (label, symbol) = ("Image", "photo")
        case "artifact_file_artifact": (label, symbol, opensInSheet) = ("Files", "paperclip", false)
        case "artifact_task_artifact": (label, symbol) = ("Task", "list.bullet.rectangle")
        case "artifact_progress_tracker_artifact": (label, symbol) = ("Progress", "chart.bar.doc.horizontal")
        case "artifact_chain_of_thought_artifact": (label, symbol) = ("Steps", "point.3.connected.trianglepath.dotted")
        case "artifact_test_results_artifact": (label, symbol) = ("Test Results", "checkmark.seal")
        case "artifact_schema_display_artifact": (label, symbol) = ("API Endpoint", "curlybraces")
        case "artifact_option_list_artifact": (label, symbol, opensInSheet) = ("Options", "list.bullet.circle", false)
        case "artifact_question_flow_artifact": (label, symbol, opensInSheet) = ("Questions", "questionmark.bubble", false)
        case "artifact_approval_card_artifact": (label, symbol, opensInSheet) = ("Approval", "hand.raised", false)
        case "artifact_confirmation_artifact": (label, symbol, opensInSheet) = ("Confirmation", "checkmark.shield", false)
        default: (label, symbol) = (Part.humanize(name), "square.on.square")
        }
    }
}

/// The artifact's content. `compact` limits long content inline; the sheet shows all of it.
private struct ArtifactBody: View {
    let name: String
    let part: JSON
    let args: JSON
    let compact: Bool
    @Environment(ChatStore.self) private var chat: ChatStore?

    private func submit(_ text: String) { chat?.send(text) }
    private var canSubmit: Bool { chat != nil && chat?.streaming == false }

    var body: some View {
        switch name {
        case "artifact_plan_artifact": PlanBody(args: args)
        case "artifact_code_block_artifact":
            MarkdownText(markdown: MarkdownText.fenced(args["code"]?.string ?? "", language: args["language"]?.string))
        case "artifact_snippet_artifact":
            MarkdownText(markdown: MarkdownText.fenced(args["code"]?.string ?? "", language: nil))
        case "artifact_data_table_artifact": DataTableBody(args: args, compact: compact)
        case "artifact_terminal_artifact": TerminalBody(args: args)
        case "artifact_stack_trace_artifact":
            MonoBlock(text: args["trace"]?.string ?? "", tint: .red, compact: compact)
        case "artifact_image_artifact": ImageBody(args: args)
        case "artifact_file_artifact":
            let files = (Part.artifactOutput(part)?["files"]?.array ?? args["files"]?.array ?? [])
            FileChips(files: files.map { FileRef(json: $0) }, alignment: .leading)
        case "artifact_task_artifact":
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array((args["items"]?.array ?? []).enumerated()), id: \.offset) { _, item in
                    Label(item["text"]?.string ?? item["content"]?.string ?? "", systemImage: "circle")
                        .labelStyle(BulletLabelStyle())
                }
            }
        case "artifact_progress_tracker_artifact": StepsBody(steps: args["steps"]?.array ?? [], footer: args["choice"]?["summary"]?.string)
        case "artifact_chain_of_thought_artifact": StepsBody(steps: args["steps"]?.array ?? [], footer: nil)
        case "artifact_test_results_artifact": TestResultsBody(args: args)
        case "artifact_schema_display_artifact": SchemaBody(args: args)
        case "artifact_option_list_artifact":
            ChoiceButtons(options: (args["options"]?.array ?? []).map {
                ($0["label"]?.string ?? "", $0["description"]?.string, $0["disabled"]?.bool == true)
            }, enabled: canSubmit, submit: submit)
        case "artifact_question_flow_artifact":
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array((args["steps"]?.array ?? []).enumerated()), id: \.offset) { _, step in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(step["question"]?.string ?? "").font(.body.weight(.medium))
                        if let d = step["description"]?.string { Text(d).font(.callout).foregroundStyle(.secondary) }
                        ChoiceButtons(options: (step["options"]?.array ?? []).map { ($0["label"]?.string ?? "", nil, false) },
                                      enabled: canSubmit, submit: submit)
                    }
                }
            }
        case "artifact_approval_card_artifact", "artifact_confirmation_artifact":
            ApprovalBody(args: args, enabled: canSubmit, submit: submit)
        default:
            JSONBlock(json: args)
        }
    }
}

// MARK: Bodies

private struct PlanBody: View {
    let args: JSON

    var body: some View {
        let todos = args["todos"]?.array ?? []
        let done = todos.filter { $0["status"]?.string == "completed" }.count
        VStack(alignment: .leading, spacing: 10) {
            if let d = args["description"]?.string { Text(d).font(.callout).foregroundStyle(.secondary) }
            if !todos.isEmpty {
                ProgressView(value: Double(done), total: Double(todos.count)) {
                    Text("\(done) of \(todos.count) done").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                let status = todo["status"]?.string ?? "pending"
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StatusSymbol(status: status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(todo["label"]?.string ?? "")
                            .strikethrough(status == "cancelled")
                            .foregroundStyle(status == "completed" || status == "cancelled" ? .secondary : .primary)
                        if let d = todo["description"]?.string {
                            Text(d).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(status.replacingOccurrences(of: "_", with: " "))
            }
        }
        .textSelection(.enabled)
    }
}

/// Status symbol for plan todos, progress steps and test cases.
struct StatusSymbol: View {
    let status: String
    var body: some View {
        switch status {
        case "completed", "complete", "passed", "success":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "in_progress", "in-progress", "active":
            ProgressView().controlSize(.mini).frame(width: 16)
        case "failed", "error":
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case "cancelled", "skipped":
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        default:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}

private struct StepsBody: View {
    let steps: [JSON]
    let footer: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StatusSymbol(status: step["status"]?.string ?? "complete")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step["label"]?.string ?? "")
                        if let d = step["description"]?.string { Text(d).font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }
            if let footer { Text(footer).font(.callout).foregroundStyle(.secondary) }
        }
        .textSelection(.enabled)
    }
}

private struct DataTableBody: View {
    let args: JSON
    let compact: Bool

    var body: some View {
        let columns = (args["columns"]?.array ?? []).map {
            (key: $0["key"]?.string ?? $0.string ?? "", label: $0["label"]?.string ?? $0["key"]?.string ?? $0.string ?? "")
        }
        let allRows = args["rows"]?.array ?? []
        let rows = compact ? Array(allRows.prefix(12)) : allRows
        VStack(alignment: .leading, spacing: 6) {
            if let caption = args["caption"]?.string { Text(caption).font(.caption).foregroundStyle(.secondary) }
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        ForEach(columns, id: \.key) { Text($0.label).font(.callout.weight(.semibold)) }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(columns, id: \.key) { col in
                                Text(row[col.key]?.inlineText ?? "").font(.callout)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.bottom, 4)
            }
            if rows.count < allRows.count {
                Text("\(allRows.count - rows.count) more rows — open to see all").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct TerminalBody: View {
    let args: JSON
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cmd = args["command"]?.string {
                Text("$ \(cmd)").font(.callout.monospaced().weight(.medium)).textSelection(.enabled)
            }
            if let out = args["stdout"]?.string, !out.isEmpty { MonoBlock(text: out, tint: nil, compact: true) }
            if let err = args["stderr"]?.string, !err.isEmpty { MonoBlock(text: err, tint: .red, compact: true) }
            if let code = args["exitCode"]?.number {
                Label("Exit code \(Int(code))", systemImage: code == 0 ? "checkmark.circle" : "xmark.circle")
                    .font(.caption).foregroundStyle(code == 0 ? Color.secondary : Color.red)
            }
        }
    }
}

private struct MonoBlock: View {
    let text: String
    let tint: Color?
    let compact: Bool
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(tint ?? .primary)
                .textSelection(.enabled)
                .fixedSize()
                .padding(10)
        }
        .defaultScrollAnchor(.topLeading)
        .frame(maxHeight: compact ? 220 : .infinity)
        .fixedSize(horizontal: false, vertical: compact)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ImageBody: View {
    let args: JSON
    @Environment(AppStore.self) private var app: AppStore?

    var body: some View {
        // Inline images are decoded once (InlineImageCache), never per render.
        if let b64 = args["base64"]?.string, !b64.isEmpty {
            inline(b64, label: args["alt"]?.string ?? "Generated image")
        } else if let string = args["url"]?.string, string.hasPrefix("data:") {
            inline(string, label: args["alt"]?.string ?? "Image")
        } else if let url = FileRef.resolve(args["url"]?.string, base: app?.api.base) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: { ProgressView() }
            .frame(maxHeight: 420)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel(args["alt"]?.string ?? "Image")
        }
    }

    private func inline(_ source: String, label: String) -> some View {
        DecodedImage(source: source) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        }
        .frame(maxHeight: 420)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(label)
    }
}

private struct TestResultsBody: View {
    let args: JSON
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = args["summary"], s != .null {
                HStack(spacing: 14) {
                    Label("\(Int(s["passed"]?.number ?? 0)) passed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Label("\(Int(s["failed"]?.number ?? 0)) failed", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    Label("\(Int(s["skipped"]?.number ?? 0)) skipped", systemImage: "minus.circle").foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            ForEach(Array((args["suites"]?.array ?? []).enumerated()), id: \.offset) { _, suite in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array((suite["tests"]?.array ?? []).enumerated()), id: \.offset) { _, test in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                StatusSymbol(status: test["status"]?.string ?? "")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(test["name"]?.string ?? "").font(.callout)
                                    if let e = test["errorMessage"]?.string {
                                        Text(e).font(.caption.monospaced()).foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                    }
                    .textSelection(.enabled)
                } label: {
                    HStack(spacing: 6) {
                        StatusSymbol(status: suite["status"]?.string ?? "")
                        Text(suite["name"]?.string ?? "").font(.callout.weight(.medium))
                    }
                }
            }
        }
    }
}

private struct SchemaBody: View {
    let args: JSON
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(args["method"]?.string ?? "GET")
                    .font(.caption.monospaced().weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
                Text(args["path"]?.string ?? "/").font(.callout.monospaced())
            }
            if let d = args["description"]?.string { Text(d).font(.callout).foregroundStyle(.secondary) }
            ForEach(["parameters", "requestBody", "responseBody"], id: \.self) { key in
                if let list = args[key]?.array, !list.isEmpty {
                    Text(Part.humanize(key == "requestBody" ? "request_body" : key == "responseBody" ? "response_body" : key))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(list.enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(p["name"]?.string ?? "").font(.callout.monospaced())
                            Text(p["type"]?.string ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                            if p["required"]?.bool == true { Text("required").font(.caption).foregroundStyle(.orange) }
                            if let d = p["description"]?.string { Text(d).font(.callout).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }
}

private struct ChoiceButtons: View {
    let options: [(label: String, detail: String?, disabled: Bool)]
    let enabled: Bool
    let submit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button { submit(option.label) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label)
                        if let d = option.detail, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(!enabled || option.disabled)
                .help("Send “\(option.label)”")
            }
        }
    }
}

private struct ApprovalBody: View {
    let args: JSON
    let enabled: Bool
    let submit: (String) -> Void

    var body: some View {
        let confirm = args["confirmLabel"]?.string ?? (args["message"] != nil ? "Confirm" : "Approve")
        let cancel = args["cancelLabel"]?.string ?? (args["message"] != nil ? "Cancel" : "Deny")
        VStack(alignment: .leading, spacing: 10) {
            if let m = args["message"]?.string { Text(m) }
            if let d = args["description"]?.string ?? args["detail"]?.string { Text(d).font(.callout).foregroundStyle(.secondary) }
            ForEach(Array((args["metadata"]?.array ?? []).enumerated()), id: \.offset) { _, item in
                LabeledContent(item["label"]?.string ?? "", value: item["value"]?.string ?? "").font(.callout)
            }
            HStack {
                Spacer()
                Button(cancel) { submit(cancel) }.disabled(!enabled)
                Button(confirm, role: args["variant"]?.string == "destructive" ? .destructive : nil) { submit(confirm) }
                    .buttonStyle(.borderedProminent)
                    .tint(args["variant"]?.string == "destructive" ? .red : nil)
                    .disabled(!enabled)
            }
        }
        .textSelection(.enabled)
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.caption2).foregroundStyle(.tertiary)
            configuration.title
        }
    }
}
