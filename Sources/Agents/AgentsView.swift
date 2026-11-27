import SwiftUI

/// Agents screen (detail column): a gallery of agents, drilling into a detail page.
/// Runtime (user-defined) agents can be built, edited, shared and deleted here.
///
/// Regular width (Mac, iPad) shows an adaptive grid of cards; compact width (iPhone) an
/// inset-grouped list. Both group "Your Agents" (runtime) above "Built-in".
struct AgentsView: View {
    @Environment(AppStore.self) private var app
    @State private var model = AgentsModel()
    @State private var path: [String] = []
    @State private var search = ""
    @State private var creating = false
    @State private var deleting: Agent?
    @State private var editing: RuntimeAgent?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

    private var filtered: [Agent] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return app.agents }
        return app.agents.filter {
            ($0.name ?? $0.id).localizedCaseInsensitiveContains(q)
                || ($0.model ?? "").localizedCaseInsensitiveContains(q)
                || (model.details[$0.id]?.description ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    /// (title, agents) per non-empty group, runtime agents first.
    private var sections: [(title: String, agents: [Agent])] {
        let agents = filtered
        let yours = agents.filter { model.runtime[$0.id] != nil }
        let builtIn = agents.filter { model.runtime[$0.id] == nil }
        // Until we know which agents are runtime agents, don't split them.
        if !model.loaded { return [("", agents)] }
        return [("Your Agents", yours), ("Built-in", builtIn)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Agents")
                .navigationDestination(for: String.self) { id in
                    AgentDetailView(agentID: id, onDeleted: { path.removeAll { $0 == id } })
                        // Pushed views inside a split view don't inherit the stack's environment on macOS.
                        .environment(model)
                }
        }
        .environment(model)
        .task { await model.reload(app.api) }
        .sheet(isPresented: $creating) {
            AgentEditorView(agent: nil) { created in path = [created.id] }
                .environment(model)
        }
        .sheet(item: $editing) { agent in
            AgentEditorView(agent: agent) { _ in }
                .environment(model)
        }
        .confirmationDialog("Delete \(deleting?.name ?? "agent")?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { agent in
            Button("Delete Agent", role: .destructive) { Task { await delete(agent) } }
        } message: { _ in
            Text("Existing chats keep their history, but nobody can start new chats with this agent.")
        }
    }

    // MARK: Layout

    @ViewBuilder private var content: some View {
        Group {
            if compact { list } else { grid }
        }
        .overlay { emptyState }
        #if os(macOS)
        .searchable(text: $search, placement: .toolbar, prompt: "Search Agents")
        #else
        .searchable(text: $search, prompt: "Search Agents")
        .refreshable { await refresh() }
        #endif
        .toolbar {
            #if os(macOS)
            // iOS refreshes with pull-to-refresh instead.
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .help("Reload agents")
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button("New Agent", systemImage: "plus") { creating = true }
                    .help("Build a new agent")
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let banner = bannerError { RetryBanner(message: banner) { Task { await refresh() } } }
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        if !section.title.isEmpty {
                            Text(section.title)
                                .font(.title3.bold())
                                .accessibilityAddTraits(.isHeader)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                            ForEach(section.agents) { agent in
                                Button { path.append(agent.id) } label: { AgentCardContent(agent: agent) }
                                    .buttonStyle(AgentCardButtonStyle())
                                    .accessibilityHint("Shows agent details")
                                    .contextMenu { menu(for: agent) }
                                    .task(id: agent.id) { await model.loadDetails(agent.id, api: app.api) }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(.background)
    }

    private var list: some View {
        List {
            if let banner = bannerError {
                RetryBanner(message: banner) { Task { await refresh() } }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sections, id: \.title) { section in
                Section {
                    ForEach(section.agents) { agent in
                        NavigationLink(value: agent.id) { AgentRowContent(agent: agent) }
                            .contextMenu { menu(for: agent) }
                            .swipeActions { swipeActions(for: agent) }
                            .task(id: agent.id) { await model.loadDetails(agent.id, api: app.api) }
                    }
                } header: {
                    if !section.title.isEmpty { Text(section.title) }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    @ViewBuilder private var emptyState: some View {
        if app.agents.isEmpty {
            if !model.loaded {
                ProgressView("Loading Agents…")
            } else if let error = model.error {
                ContentUnavailableView {
                    Label("Couldn't Load Agents", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await refresh() } }
                }
            } else {
                ContentUnavailableView {
                    Label("No Agents", systemImage: "person.2.badge.gearshape")
                } description: {
                    Text("Build an agent with a model, instructions and tools.")
                } actions: {
                    Button("New Agent") { creating = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: search)
        }
    }

    /// A failed runtime-agent load while the list itself is there: say so above the agents.
    private var bannerError: String? { app.agents.isEmpty ? nil : model.error }

    // MARK: Actions

    @ViewBuilder private func menu(for agent: Agent) -> some View {
        let runtime = model.runtime[agent.id]
        Button("Start Chat", systemImage: "bubble.left") { app.startChat(agent: agent.id) }
            .disabled(runtime.map { !$0.active } ?? false)
        Button("Show Details", systemImage: "info.circle") { path.append(agent.id) }
        if let runtime, runtime.canEdit {
            Divider()
            Button("Edit…", systemImage: "pencil") { editing = runtime }
        }
        if let runtime, runtime.canDelete {
            Button("Delete…", systemImage: "trash", role: .destructive) { deleting = agent }
        }
    }

    @ViewBuilder private func swipeActions(for agent: Agent) -> some View {
        if let runtime = model.runtime[agent.id] {
            if runtime.canDelete {
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = agent }
            }
            if runtime.canEdit {
                Button("Edit", systemImage: "pencil") { editing = runtime }
            }
        }
    }

    private func refresh() async {
        try? await app.loadLists()
        await model.reload(app.api)
    }

    private func delete(_ agent: Agent) async {
        do {
            try await app.api.deleteRuntimeAgent(agent.id)
            try await app.loadLists()
            await model.reload(app.api)
        } catch {
            model.error = error.localizedDescription
        }
    }
}

// MARK: - Cards and rows

/// Display strings shared by the card and the row.
private struct AgentSummary {
    let name: String
    let subtitle: String
    let model: String
    let runtime: RuntimeAgent?

    @MainActor init(_ agent: Agent, model: AgentsModel) {
        runtime = model.runtime[agent.id]
        name = agent.name ?? agent.id
        let description = model.details[agent.id]?.description?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").first
        if let description, !description.isEmpty {
            subtitle = description
        } else {
            subtitle = runtime != nil ? "Custom agent" : "Built-in agent"
        }
        // "openai/gpt-oss-120b" reads as "gpt-oss-120b"; the detail page shows the full id.
        self.model = agent.model.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? "Default model"
    }

    var inactive: Bool { runtime.map { !$0.active } ?? false }
}

/// Gallery card: icon tile, name, one-line-ish description, then model and capabilities.
private struct AgentCardContent: View {
    let agent: Agent
    @Environment(AgentsModel.self) private var model

    var body: some View {
        let summary = AgentSummary(agent, model: model)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                AgentIcon(id: agent.id, name: summary.name, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(summary.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Label(summary.model, systemImage: "cpu")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                CapabilityBadges(fileUpload: agent.file_upload ?? false, rag: agent.rag ?? false,
                                 vision: agent.vision ?? false, inactive: summary.inactive, style: .symbols)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// iPhone list row: icon, name, description, model and capabilities.
private struct AgentRowContent: View {
    let agent: Agent
    @Environment(AgentsModel.self) private var model

    var body: some View {
        let summary = AgentSummary(agent, model: model)
        HStack(spacing: 14) {
            AgentIcon(id: agent.id, name: summary.name, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(summary.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(summary.model).lineLimit(1)
                    CapabilityBadges(fileUpload: agent.file_upload ?? false, rag: agent.rag ?? false,
                                     vision: agent.vision ?? false, inactive: summary.inactive, style: .symbols)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Card chrome: neutral grouped background with hover (Mac, iPad pointer) and press feedback.
private struct AgentCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AgentCardChrome(configuration: configuration)
    }
}

private struct AgentCardChrome: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        configuration.label
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                shape.fill(.background.secondary)
                    .overlay(shape.fill(.primary.opacity(configuration.isPressed ? 0.08 : hovering ? 0.04 : 0)))
            }
            .overlay(shape.strokeBorder(.primary.opacity(hovering ? 0.14 : 0.07), lineWidth: 1))
            .contentShape(shape)
            #if os(iOS)
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.lift)
            #endif
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: hovering)
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// Inline, non-blocking error with a retry (agents and workflows screens).
struct RetryBanner: View {
    let message: String
    var retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 8)
            Button("Try Again", action: retry).controlSize(.small)
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
