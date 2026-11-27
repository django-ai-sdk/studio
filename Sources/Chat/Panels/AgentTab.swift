import SwiftUI

struct AgentTab: View {
    let threadID: String?

    @Environment(AppStore.self) private var app
    @Environment(ChatStore.self) private var chat
    @State private var info: AgentInfo?
    @State private var tools: AgentTools?
    @State private var usage: ThreadTokenUsage?
    @State private var files: ThreadFileMeta?
    @State private var memories: [ThreadMemory] = []
    @State private var error: String?
    @State private var switching = false

    private var agentID: String? { chat.agentID }
    private var listed: Agent? { app.agents.first { $0.id == agentID } }
    private var name: String { info?.name ?? listed?.name ?? "Agent" }

    var body: some View {
        Form {
            if let agentID {
                header(agentID)
            } else {
                ContentUnavailableView("No Agent", systemImage: "cpu",
                                       description: Text("There are no agents to chat with."))
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            if let threadID {
                threadSection
                if !memories.isEmpty { memoriesSection }
                Section("Actions") { ThreadActionButtons(threadID: threadID) }
            }
            configuration
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task(id: agentID) { await loadAgent() }
        .task(id: StatsKey(thread: threadID, streaming: chat.streaming)) { await loadThread() }
    }

    private struct StatsKey: Hashable { let thread: String?; let streaming: Bool }

    private func header(_ id: String) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                AgentIcon(id: id, name: name, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.title3.weight(.semibold))
                    Text(info?.model ?? listed?.model ?? "Default model")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    CapabilityBadges(fileUpload: info?.file_upload ?? listed?.file_upload ?? false,
                                     rag: info?.rag ?? listed?.rag ?? false,
                                     vision: info?.vision ?? listed?.vision ?? false)
                }
            }
            .padding(.vertical, 2)
            if let description = info?.description, !description.isEmpty {
                Text(description).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if app.agents.count > 1 { agentPicker }
        }
    }

    private var agentPicker: some View {
        Picker(selection: Binding(get: { agentID ?? "" }, set: { new in Task { await switchAgent(to: new) } })) {
            ForEach(app.agents) { Text($0.name ?? $0.id).tag($0.id) }
        } label: {
            HStack(spacing: 6) {
                Text(threadID == nil ? "Agent" : "Change agent")
                if switching { ProgressView().controlSize(.mini) }
            }
        }
        .pickerStyle(.menu)
        .disabled(switching || chat.streaming)
        .help(threadID == nil ? "The agent this chat starts with" : "Answer the rest of this thread with another agent")
    }

    private var threadSection: some View {
        Section("This Thread") {
            LabeledContent("Messages", value: "\(chat.messages.count)")
            if let usage, usage.total_tokens > 0 {
                LabeledContent("Tokens") {
                    Text(formatTokens(usage.total_tokens)).help("\(usage.total_tokens.formatted()) tokens")
                }
                LabeledContent("Prompt", value: formatTokens(usage.prompt_tokens))
                LabeledContent("Completion", value: formatTokens(usage.completion_tokens))
            }
            if let files { LabeledContent("Files", value: "\(files.file_count)") }
        }
        .monospacedDigit()
    }

    private var memoriesSection: some View {
        Section("Memories") {
            ForEach(memories) { memory in
                LabeledContent {
                    if memory.active == false { Text("Off") }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(memory.name)
                            if let n = memory.document_count {
                                Text(n == 1 ? "1 document" : "\(n) documents")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: { Image(systemName: "cylinder.split.1x2").foregroundStyle(.secondary) }
                }
            }
        }
    }

    @ViewBuilder private var configuration: some View {
        if let info, let instructions = info.instructions, !instructions.isEmpty {
            Section("Instructions") {
                DisclosureGroup {
                    Text(instructions)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(instructions.split(separator: "\n").first.map(String.init) ?? instructions)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
        }
        if let tools, !tools.tools.isEmpty {
            Section("Tools (\(tools.tools.count))") {
                ForEach(tools.tools) { PanelToolRow(tool: $0) }
            }
        }
        if let integrations = tools?.integrations, !integrations.isEmpty {
            Section("Integrations (\(integrations.count))") {
                ForEach(integrations) { server in
                    LabeledContent {
                        Text(server.status.capitalized)
                            .foregroundStyle(["active", "connected"].contains(server.status) ? .green : .orange)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(server.label)
                                if !server.tool_names.isEmpty {
                                    Text(server.tool_names.joined(separator: ", "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        } icon: { Image(systemName: "powerplug").foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private func loadAgent() async {
        guard let agentID else { return }
        info = nil
        tools = nil
        do {
            async let i = app.api.agentInfo(agentID)
            async let t = try? app.api.agentTools(agentID)
            let (newInfo, newTools) = (try await i, await t)
            guard !Task.isCancelled else { return }
            info = newInfo
            tools = newTools
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func loadThread() async {
        guard let threadID, !chat.streaming else { return }
        async let u = try? app.api.threadTokens(threadID)
        async let f = try? app.api.threadFileMeta(threadID)
        async let m = try? app.api.threadMemories(threadID)
        let loaded = await (u, f, m ?? [])
        guard !Task.isCancelled else { return }
        (usage, files, memories) = loaded
    }

    private func switchAgent(to id: String) async {
        guard id != agentID else { return }
        guard let threadID else { chat.agentID = id; return }
        switching = true
        defer { switching = false }
        do {
            try await app.api.setThreadAgent(threadID, agent: id)
            chat.agentID = id
            try? await app.refreshThreads()
            memories = (try? await app.api.threadMemories(threadID)) ?? []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PanelToolRow: View {
    let tool: AgentTool

    var body: some View {
        if let children = tool.children, !children.isEmpty {
            DisclosureGroup {
                ForEach(children) { PanelToolRow(tool: $0) }
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
                        .lineLimit(2)
                }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .help(tool.description ?? "")
    }
}
