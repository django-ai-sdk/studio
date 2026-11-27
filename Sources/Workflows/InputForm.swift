import SwiftUI

struct InputField: Identifiable {
    let name: String
    let type: String
    let description: String
    let required: Bool
    let defaultValue: JSON?
    let options: [JSON]?
    let conversation: Bool

    var id: String { name }
    var isJSON: Bool { ["list", "dict", "object"].contains(type) && !conversation }
    var hasDefault: Bool { defaultValue != nil && defaultValue != .null }
    var mustFill: Bool { required && !hasDefault }

    init(name: String, field: JSON, conversation: Bool) {
        self.name = name
        type = field["type"]?.string ?? "str"
        description = field["description"]?.string ?? ""
        required = field["required"]?.bool ?? true
        defaultValue = field["default"]
        options = field["enum"]?.array.flatMap { $0.isEmpty ? nil : $0 }
        self.conversation = conversation && (type == "list" || type == "str")
    }

    static func of(_ workflow: WorkflowItem) -> [InputField] {
        let history = workflow.historyInputs
        return workflow.inputFields.map { InputField(name: $0.name, field: $0.field, conversation: history.contains($0.name)) }
    }

    var initialText: String {
        guard hasDefault, let value = defaultValue else { return "" }
        if let options, let i = options.firstIndex(of: value) { return String(i) }
        switch value {
        case .string(let s): return s
        case .number(let n): return type == "int" ? String(Int(n)) : String(n)
        default: return value.pretty
        }
    }
}

struct InputDraft: Equatable {
    var text: [String: String] = [:]
    var flags: [String: Bool] = [:]

    init(_ fields: [InputField] = []) {
        for f in fields {
            if f.type == "bool" && f.options == nil { flags[f.name] = f.defaultValue?.bool ?? false }
            else { text[f.name] = f.initialText }
        }
    }

    func inputs(_ fields: [InputField]) -> Result<[String: JSON], InputProblems> {
        var out: [String: JSON] = [:]
        var problems: [String: String] = [:]
        for f in fields {
            if f.type == "bool" && f.options == nil { out[f.name] = .bool(flags[f.name] ?? false); continue }
            let raw = text[f.name] ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if f.mustFill { problems[f.name] = "Fill this in to run." }
                continue
            }
            if let options = f.options {
                if let i = Int(raw), options.indices.contains(i) { out[f.name] = options[i] }
                continue
            }
            switch f.type {
            case "int":
                if let v = Int(trimmed) { out[f.name] = .number(Double(v)) } else { problems[f.name] = "Enter a whole number." }
            case "float":
                if let v = Double(trimmed.replacingOccurrences(of: ",", with: ".")) { out[f.name] = .number(v) }
                else { problems[f.name] = "Enter a number." }
            case _ where f.conversation && f.type == "list":
                out[f.name] = .array([.object(["role": .string("user"), "content": .string(raw)])])
            case _ where f.isJSON:
                if let v = try? JSONDecoder().decode(JSON.self, from: Data(trimmed.utf8)) {
                    out[f.name] = v
                } else { problems[f.name] = "Not valid JSON." }
            default:
                out[f.name] = .string(raw)
            }
        }
        return problems.isEmpty ? .success(out) : .failure(InputProblems(byField: problems))
    }
}

struct InputProblems: Error { let byField: [String: String] }

struct InputFormRows: View {
    let fields: [InputField]
    @Binding var draft: InputDraft
    let problems: [String: String]
    var onSubmit: () -> Void = {}

    var body: some View {
        ForEach(fields) { field in
            row(field)
            if let problem = problems[field.name] {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private func text(_ name: String) -> Binding<String> {
        Binding { draft.text[name] ?? "" } set: { draft.text[name] = $0 }
    }

    @ViewBuilder private func label(_ f: InputField) -> some View {
        Text(f.name.replacingOccurrences(of: "_", with: " ").capitalized + (f.mustFill ? "" : " (optional)"))
        if !f.description.isEmpty { Text(f.description) }
    }

    @ViewBuilder private func row(_ f: InputField) -> some View {
        if let options = f.options {
            Picker(selection: text(f.name)) {
                if !f.mustFill { Text("None").tag("") }
                ForEach(options.indices, id: \.self) { i in Text(Self.display(options[i])).tag(String(i)) }
            } label: { label(f) }
        } else if f.type == "bool" {
            Toggle(isOn: Binding { draft.flags[f.name] ?? false } set: { draft.flags[f.name] = $0 }) { label(f) }
        } else if f.type == "int" || f.type == "float" {
            TextField(text: text(f.name), prompt: Text(f.type == "int" ? "0" : "0.0")) { label(f) }
                .monospacedDigit()
        } else if f.isJSON {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent { Text(f.type == "list" ? "JSON list" : "JSON object").foregroundStyle(.secondary) } label: { label(f) }
                TextEditor(text: text(f.name))
                    .font(.body.monospaced())
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) { label(f) }
                    #if os(iOS)
                    .padding(.horizontal, 20)
                    #endif
                ChatStyleField(text: text(f.name), prompt: f.conversation ? "Message" : "Text", onSubmit: onSubmit)
            }
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
    }

    static func display(_ v: JSON) -> String {
        switch v {
        case .string(let s): s
        case .number(let n): n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): b ? "true" : "false"
        default: v.pretty
        }
    }
}

private struct ChatStyleField: View {
    @Binding var text: String
    let prompt: String
    let onSubmit: () -> Void
    @State private var height: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ComposerTextView(text: $text, height: $height, placeholder: prompt, focusKey: nil,
                             onSubmit: onSubmit, onPaste: { _ in false })
                .frame(height: height)
                .padding(.horizontal, 4)
            Color.clear.frame(height: 28)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .composerSurface()
    }
}
