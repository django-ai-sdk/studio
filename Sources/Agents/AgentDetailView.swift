import SwiftUI

struct AgentDetailView: View {
    let agentID: String
    var onDeleted: () -> Void

    @Environment(AppStore.self) private var app
    @Environment(AgentsModel.self) private var model
    @State private var info: AgentInfo?
    @State private var tools: AgentTools?
    @State private var error: String?
    @State private var editing = false
    @State private var confirmDelete = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

    private var runtime: RuntimeAgent? { model.runtime[agentID] }
    private var listed: Agent? { app.agents.first { $0.id == agentID } }
    private var name: String { runtime?.name ?? info?.name ?? listed?.name ?? agentID }
    private var inactive: Bool { runtime.map { !$0.active } ?? false }

    var body: some View {
        Form {
            header
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            if let description = info?.description, !description.isEmpty {
                Section("Description") { Text(description).textSelection(.enabled) }
            }
            Section("Instructions") {
                if let text = runtime?.system_prompt ?? info?.instructions, !text.isEmpty {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if info == nil && error == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Text("No instructions").foregroundStyle(.secondary)
                }
            }
            toolsSection
            if let runtime { settingsSection(runtime) }
            if let runtime, runtime.canManageAccess {
                AgentAccessSection(agentID: runtime.id)
            }
            if let runtime, runtime.canDelete {
                Section {
                    Button("Delete Agent", role: .destructive) { confirmDelete = true }
                        #if os(iOS)
                        .frame(maxWidth: .infinity)
                        #endif
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let runtime, runtime.canEdit {
                ToolbarItem {
                    Button("Edit", systemImage: "pencil") { editing = true }
                        .help("Edit this agent")
                }
            }
            if let runtime, runtime.canDelete {
                ToolbarItem {
                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Start Chat", systemImage: "bubble.left") { app.startChat(agent: agentID) }
                            .disabled(inactive)
                        Divider()
                        Button("Delete Agent…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                    .help("More actions")
                }
            }
        }
        .task(id: agentID) { await load() }
        .sheet(isPresented: $editing) {
            if let runtime {
                AgentEditorView(agent: runtime) { _ in Task { await load() } }
                    .environment(model)
            }
        }
        .confirmationDialog("Delete \(name)?", isPresented: $confirmDelete) {
            Button("Delete Agent", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Existing chats keep their history, but nobody can start new chats with this agent.")
        }
    }

    private var modelName: String { runtime?.model ?? info?.model ?? listed?.model ?? "Default model" }

    private var header: some View {
        Section {
            Group {
                if compact {
                    VStack(spacing: 12) {
                        AgentIcon(id: agentID, name: name, size: 88)
                        headerText(alignment: .center)
                        startChat.frame(maxWidth: .infinity).padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    HStack(alignment: .center, spacing: 18) {
                        AgentIcon(id: agentID, name: name, size: 72)
                        headerText(alignment: .leading)
                        Spacer(minLength: 12)
                        startChat
                    }
                }
            }
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    private func headerText(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(name)
                .font(.title2.bold())
                .multilineTextAlignment(alignment == .center ? .center : .leading)
            Text(modelName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            CapabilityBadges(
                fileUpload: runtime?.file_upload ?? info?.file_upload ?? listed?.file_upload ?? false,
                rag: info?.rag ?? listed?.rag ?? false,
                vision: runtime?.vision ?? info?.vision ?? listed?.vision ?? false,
                custom: runtime != nil,
                inactive: inactive)
                .padding(.top, 2)
        }
    }

    private var startChat: some View {
        Button {
            app.startChat(agent: agentID)
        } label: {
            Label("Start Chat", systemImage: "bubble.left.fill")
                .frame(maxWidth: compact ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(inactive)
        .help(inactive ? "This agent is inactive" : "Start a new chat with \(name)")
    }

    @ViewBuilder private var toolsSection: some View {
        Section("Tools") {
            if let tools {
                if tools.tools.isEmpty && (tools.integrations ?? []).isEmpty {
                    Text("This agent has no tools").foregroundStyle(.secondary)
                }
                ForEach(tools.tools) { ToolRow(tool: $0) }
                ForEach(tools.integrations ?? []) { integration in
                    DisclosureGroup {
                        ForEach(integration.tool_names, id: \.self) { Text($0).font(.callout.monospaced()) }
                    } label: {
                        HStack {
                            Label(integration.label, systemImage: "puzzlepiece.extension")
                            Spacer()
                            Text(integration.status.capitalized)
                                .font(.caption)
                                .foregroundStyle(integration.status == "active" ? .green : .orange)
                        }
                    }
                }
            } else if error == nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func settingsSection(_ agent: RuntimeAgent) -> some View {
        Section("Settings") {
            LabeledContent("Slug") { Text(agent.slug).textSelection(.enabled).font(.callout.monospaced()) }
            LabeledContent("Base class", value: agent.agent.isEmpty
                ? "Default" : (model.bases.first { $0.path == agent.agent }?.name ?? agent.agent))
            if let info { LabeledContent("Class", value: info.class_name) }
            if !agent.memories.isEmpty { LabeledContent("Knowledge", value: agent.memories.joined(separator: ", ")) }
            LabeledContent("Follow-up suggestions", value: agent.suggestion_enabled ? "On" : "Off")
            LabeledContent("Automatic titles", value: agent.title_generation ? "On" : "Off")
            LabeledContent("Message history", value: agent.max_history.map { "\($0) messages" } ?? "All")
            LabeledContent("Status", value: agent.active ? "Active" : "Inactive")
        }
    }

    private func load() async {
        let id = agentID
        do {
            async let i = app.api.agentInfo(id)
            async let t = app.api.agentTools(id)
            let (newInfo, newTools) = try await (i, t)
            guard !Task.isCancelled, id == agentID else { return }
            (info, tools) = (newInfo, newTools)
            error = nil
        } catch {
            guard !Task.isCancelled, id == agentID else { return }
            self.error = error.localizedDescription
        }
        if model.bases.isEmpty, runtime != nil { await model.loadOptions(app.api) }
    }

    private func delete() async {
        do {
            try await app.api.deleteRuntimeAgent(agentID)
            try await app.loadLists()
            await model.reload(app.api)
            onDeleted()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ToolRow: View {
    let tool: AgentTool

    var body: some View {
        if let children = tool.children, !children.isEmpty {
            DisclosureGroup {
                ForEach(children) { ToolRow(tool: $0) }
            } label: { label(symbol: "shippingbox") }
        } else {
            label(symbol: "wrench.and.screwdriver")
        }
    }

    private func label(symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.label)
                if let d = tool.description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                    Text(d.components(separatedBy: "\n\n").first ?? d)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
        .help(tool.description ?? "")
    }
}
