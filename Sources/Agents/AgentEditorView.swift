import SwiftUI

struct AgentEditorView: View {
    let agent: RuntimeAgent?
    var onSaved: (RuntimeAgent) -> Void

    @Environment(AppStore.self) private var app
    @Environment(AgentsModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var slug = ""
    @State private var base = ""
    @State private var modelName = ""
    @State private var instructions = ""
    @State private var tools: Set<String> = []
    @State private var integrations: Set<String> = []
    @State private var memories: Set<String> = []
    @State private var suggestions = false
    @State private var titles = true
    @State private var fileUpload = false
    @State private var vision = false
    @State private var active = true
    @State private var maxHistory = ""
    @State private var saving = false
    @State private var error: String?
    @State private var initial: Snapshot?
    @State private var confirmDiscard = false

    private struct Snapshot: Equatable {
        var name, slug, base, model, instructions, maxHistory: String
        var tools, integrations, memories: Set<String>
        var suggestions, titles, fileUpload, vision, active: Bool
    }

    private var snapshot: Snapshot {
        Snapshot(name: name, slug: slug, base: base, model: modelName, instructions: instructions, maxHistory: maxHistory,
                 tools: tools, integrations: integrations, memories: memories, suggestions: suggestions,
                 titles: titles, fileUpload: fileUpload, vision: vision, active: active)
    }

    private var isDirty: Bool { initial.map { $0 != snapshot } ?? false }

    private var isEdit: Bool { agent != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var historyValue: Int? { Int(maxHistory.trimmingCharacters(in: .whitespaces)) }
    private var historyValid: Bool { maxHistory.trimmingCharacters(in: .whitespaces).isEmpty || (historyValue ?? -1) >= 0 }

    private var modelSuggestions: [String] {
        Array(Set(app.agents.compactMap(\.model) + model.runtime.values.map(\.model))).filter { !$0.isEmpty }.sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                Section {
                    TextField("Name", text: $name, prompt: Text("Support agent"))
                    HStack {
                        TextField("Model", text: $modelName, prompt: Text(isEdit ? "Keep current" : "gpt-4o"))
                        if !modelSuggestions.isEmpty {
                            Menu {
                                ForEach(modelSuggestions, id: \.self) { m in Button(m) { modelName = m } }
                            } label: {
                                Image(systemName: "chevron.up.chevron.down")
                            }
                            #if os(macOS)
                            .menuStyle(.borderlessButton)
                            #endif
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Models other agents use")
                        }
                    }
                    if let agent {
                        LabeledContent("Slug") { Text(agent.slug).font(.callout.monospaced()).textSelection(.enabled) }
                    } else {
                        TextField("Slug", text: $slug, prompt: Text("Made from the name"))
                    }
                    Picker("Base", selection: $base) {
                        Text("Default").tag("")
                        ForEach(model.bases) { Text($0.name).tag($0.path) }
                        if !base.isEmpty && !model.bases.contains(where: { $0.path == base }) {
                            Text(base).tag(base)
                        }
                    }
                } header: {
                    Text("General")
                } footer: {
                    Text("Leave the base on Default unless your team built a custom agent class.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextEditor(text: $instructions)
                        .font(.body)
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Instructions")
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("What the agent does, its tone, and what it must never do. \(instructions.count) characters.")
                        .foregroundStyle(.secondary)
                }

                Section("Tools") {
                    if model.toolOptions.isEmpty {
                        Text("No tools available").foregroundStyle(.secondary)
                    }
                    ForEach(model.toolOptions) { tool in
                        Toggle(isOn: member(tool.key, of: $tools)) {
                            Text(tool.key).font(.body.monospaced())
                            Text(tool.path).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if !model.integrations.isEmpty {
                    Section("Integrations") {
                        ForEach(model.integrations) { integration in
                            Toggle(isOn: member(integration.name, of: $integrations)) {
                                Text(integration.label)
                                if let hint = integration.hint, !hint.isEmpty { Text(hint) }
                            }
                        }
                    }
                }

                if !model.memories.isEmpty {
                    Section("Knowledge") {
                        ForEach(model.memories) { memory in
                            Toggle(isOn: member(memory.slug, of: $memories)) {
                                Text(memory.name)
                                if let n = memory.document_count { Text("\(n) document\(n == 1 ? "" : "s")") }
                            }
                        }
                    }
                }

                Section("Behaviour") {
                    Toggle("Follow-up suggestions", isOn: $suggestions)
                    Toggle("Automatic titles", isOn: $titles)
                    Toggle("File upload", isOn: $fileUpload)
                    Toggle("Vision", isOn: $vision)
                    if isEdit { Toggle("Active", isOn: $active) }
                    TextField("Message history", text: $maxHistory, prompt: Text("All"))
                        .multilineTextAlignment(.trailing)
                    if !historyValid {
                        Text("Enter a whole number, or leave empty for all messages.").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            #if os(macOS)
            .toggleStyle(.checkbox)
            #else
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle(isEdit ? "Edit \(agent?.name ?? "Agent")" : "New Agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if isDirty { confirmDiscard = true } else { dismiss() } }
                        .confirmationDialog("Discard Changes?", isPresented: $confirmDiscard) {
                            Button("Discard Changes", role: .destructive) { dismiss() }
                            Button("Keep Editing", role: .cancel) {}
                        } message: {
                            Text("Your changes to this agent will be lost.")
                        }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEdit ? "Save" : "Create") { Task { await save() } }
                        .disabled(trimmedName.isEmpty || !historyValid || saving)
                }
            }
            .disabled(saving)
        }
        .interactiveDismissDisabled(isDirty)
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 580, minHeight: 560, idealHeight: 720)
        #endif
        .task {
            fill()
            if initial == nil { initial = snapshot }
            if model.toolOptions.isEmpty && model.bases.isEmpty { await model.loadOptions(app.api) }
        }
    }

    private func member(_ key: String, of set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(key) },
                set: { on in if on { set.wrappedValue.insert(key) } else { set.wrappedValue.remove(key) } })
    }

    private func fill() {
        guard let agent, name.isEmpty else { return }
        name = agent.name
        base = agent.agent
        modelName = agent.model
        instructions = agent.system_prompt
        tools = Set(agent.tools)
        integrations = Set(agent.integrations)
        memories = Set(agent.memories)
        suggestions = agent.suggestion_enabled
        titles = agent.title_generation
        fileUpload = agent.file_upload
        vision = agent.vision
        active = agent.active
        maxHistory = agent.max_history.map(String.init) ?? ""
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var body: [String: Any] = [
            "name": trimmedName,
            "agent": base,
            "system_prompt": instructions,
            "tools": tools.sorted(),
            "integrations": integrations.sorted(),
            "memories": memories.sorted(),
            "suggestion_enabled": suggestions,
            "title_generation": titles,
            "file_upload": fileUpload,
            "vision": vision,
            "max_history": historyValue.map { $0 as Any } ?? NSNull(),
        ]
        let m = modelName.trimmingCharacters(in: .whitespaces)
        if !m.isEmpty { body["model"] = m }
        do {
            let saved: RuntimeAgent
            if let agent {
                body["active"] = active
                saved = try await app.api.updateRuntimeAgent(agent.id, body)
            } else {
                let s = slug.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { body["slug"] = s }
                saved = try await app.api.createRuntimeAgent(body)
            }
            model.runtime[saved.id] = saved
            try await app.loadLists()
            await model.reload(app.api)
            onSaved(saved)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
