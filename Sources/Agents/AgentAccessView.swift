import SwiftUI

/// Who can use or manage a runtime agent. Changes apply immediately.
/// Shown only to people who can manage the agent.
struct AgentAccessSection: View {
    let agentID: String

    @Environment(AppStore.self) private var app
    @State private var users: [AgentUserAccess] = []
    @State private var groups: [AgentGroupAccess] = []
    @State private var loaded = false
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        Section {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if loaded && users.isEmpty && groups.isEmpty {
                Text("Nobody has been added: everyone who is signed in can chat with this agent.")
                    .foregroundStyle(.secondary)
            }
            ForEach(users) { user in
                row(title: user.displayName, detail: user.email, symbol: "person.crop.circle",
                    canManage: user.can_manage) { manage in
                    try await app.api.updateAgentUser(agentID, user: user.user_id, canManage: manage)
                } remove: {
                    try await app.api.removeAgentUser(agentID, user: user.user_id)
                }
            }
            ForEach(groups) { group in
                row(title: group.group_name, detail: "Group", symbol: "person.3",
                    canManage: group.can_manage) { manage in
                    try await app.api.addAgentGroup(agentID, group: group.group_id, canManage: manage)
                } remove: {
                    try await app.api.removeAgentGroup(agentID, group: group.group_id)
                }
            }
        } header: {
            HStack {
                Text("Access")
                Spacer()
                Button("Add…", systemImage: "plus") { adding = true }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        } footer: {
            Text("People who can use the agent can chat with it; managers can also edit it and change access.")
                .foregroundStyle(.secondary)
        }
        .task(id: agentID) { await load() }
        .sheet(isPresented: $adding) {
            AddAccessSheet(agentID: agentID, existingUsers: Set(users.map(\.user_id)),
                           existingGroups: Set(groups.map(\.group_id))) {
                Task { await load() }
            }
        }
    }

    private func row(title: String, detail: String?, symbol: String, canManage: Bool,
                     setRole: @escaping (Bool) async throws -> Void,
                     remove: @escaping () async throws -> Void) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            } icon: { Image(systemName: symbol) }
            Spacer()
            Picker("Role", selection: Binding(get: { canManage }, set: { v in run { try await setRole(v) } })) {
                Text("Can use").tag(false)
                Text("Can manage").tag(true)
            }
            .labelsHidden()
            .fixedSize()
            Button("Remove", systemImage: "minus.circle") { run(remove) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove access")
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); error = nil } catch { self.error = error.localizedDescription }
            await load()
        }
    }

    private func load() async {
        let id = agentID
        do {
            async let u = app.api.agentUsers(id)
            async let g = app.api.agentGroups(id)
            let (newUsers, newGroups) = try await (u, g)
            // A newer load (another agent selected) owns the view now.
            guard !Task.isCancelled, id == agentID else { return }
            (users, groups) = (newUsers, newGroups)
        } catch {
            guard !Task.isCancelled, id == agentID else { return }
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

/// Search people or groups and add them to an agent.
private struct AddAccessSheet: View {
    let agentID: String
    let existingUsers: Set<String>
    let existingGroups: Set<Int>
    var onChange: () -> Void

    private enum Kind: String, CaseIterable { case people = "People", groups = "Groups" }

    @Environment(AppStore.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var kind = Kind.people
    @State private var query = ""
    @State private var canManage = false
    @State private var users: [UserOption] = []
    @State private var groups: [GroupOption] = []
    @State private var added: Set<String> = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Add", selection: $kind) {
                        ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Search", text: $query, prompt: Text(kind == .people ? "Name" : "Group name"))
                    Picker("Role", selection: $canManage) {
                        Text("Can use").tag(false)
                        Text("Can manage").tag(true)
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                Section("Results") {
                    switch kind {
                    case .people:
                        if users.isEmpty { Text("No people found").foregroundStyle(.secondary) }
                        ForEach(users) { user in
                            result(user.displayName, key: "u\(user.id)", present: existingUsers.contains(user.id)) {
                                try await app.api.addAgentUser(agentID, user: user.id, canManage: canManage)
                            }
                        }
                    case .groups:
                        if groups.isEmpty { Text("No groups found").foregroundStyle(.secondary) }
                        ForEach(groups) { group in
                            result(group.name, key: "g\(group.id)", present: existingGroups.contains(group.id)) {
                                try await app.api.addAgentGroup(agentID, group: group.id, canManage: canManage)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Access")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
        .task(id: "\(kind.rawValue)|\(query)") {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                switch kind {
                case .people:
                    let found = try await app.api.searchUsers(query)
                    guard !Task.isCancelled else { return }
                    users = found
                case .groups:
                    let found = try await app.api.searchGroups(query)
                    guard !Task.isCancelled else { return }
                    groups = found
                }
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func result(_ title: String, key: String, present: Bool, add: @escaping () async throws -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            if present || added.contains(key) {
                Label("Added", systemImage: "checkmark").foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            } else {
                Button("Add") {
                    Task {
                        do { try await add(); added.insert(key); onChange() } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}
