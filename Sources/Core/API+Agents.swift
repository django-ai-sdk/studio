import Foundation

struct ObjectPermissions: Decodable, Hashable {
    var can_read = false
    var can_write = false
    var can_manage = false
    var can_delete = false
}

struct AgentInfo: Decodable, Hashable {
    let id: String
    let name: String?
    let model: String?
    let class_name: String
    let description: String?
    let instructions: String?
    let file_upload: Bool?
    let rag: Bool?
    let vision: Bool?
    let permissions: ObjectPermissions?
}

struct AgentTool: Decodable, Hashable, Identifiable {
    let label: String
    let description: String?
    let children: [AgentTool]?
    var id: String { label }
}

struct AgentIntegrationStatus: Decodable, Hashable, Identifiable {
    let server_name: String
    let label: String
    let type: String
    let status: String
    let tool_names: [String]
    var id: String { server_name }
}

struct AgentTools: Decodable, Hashable {
    let tools: [AgentTool]
    let integrations: [AgentIntegrationStatus]?
}

struct RuntimeAgent: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let slug: String
    let agent: String
    let model: String
    let system_prompt: String
    let tools: [String]
    let integrations: [String]
    let memories: [String]
    let suggestion_enabled: Bool
    let title_generation: Bool
    let max_history: Int?
    let file_upload: Bool
    let vision: Bool
    let active: Bool
    let permissions: ObjectPermissions?

    var canEdit: Bool { permissions.map { $0.can_write || $0.can_manage } ?? false }
    var canDelete: Bool { permissions.map { $0.can_delete || $0.can_manage } ?? false }
    var canManageAccess: Bool { permissions?.can_manage ?? false }
}

struct RuntimeAgentBase: Decodable, Hashable, Identifiable {
    let path: String
    let name: String
    let base_system_prompt: String?
    var id: String { path }
}

struct RuntimeAgentToolOption: Decodable, Hashable, Identifiable {
    let key: String
    let path: String
    var id: String { key }
}

struct IntegrationOption: Decodable, Hashable, Identifiable {
    let name: String
    let label: String
    let hint: String?
    let kind: String?
    let connected: Bool?
    var id: String { name }
}

struct MemoryOption: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let slug: String
    let document_count: Int?
}

struct AgentUserAccess: Decodable, Hashable, Identifiable {
    let user_id: String
    let email: String?
    let first_name: String?
    let last_name: String?
    let can_manage: Bool
    var id: String { user_id }
    var displayName: String {
        let full = [first_name, last_name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return full.isEmpty ? (email?.isEmpty == false ? email! : user_id) : full
    }
}

struct AgentGroupAccess: Decodable, Hashable, Identifiable {
    let group_id: Int
    let group_name: String
    let can_manage: Bool
    var id: Int { group_id }
}

struct UserOption: Decodable, Hashable, Identifiable {
    let id: String
    let first_name: String
    let last_name: String
    var displayName: String {
        let full = "\(first_name) \(last_name)".trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? "User \(id)" : full
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let n = try? c.decode(Int.self, forKey: .id) { id = String(n) } else { id = try c.decode(String.self, forKey: .id) }
        first_name = (try? c.decode(String.self, forKey: .first_name)) ?? ""
        last_name = (try? c.decode(String.self, forKey: .last_name)) ?? ""
    }
    private enum CodingKeys: String, CodingKey { case id, first_name, last_name }
}

struct GroupOption: Decodable, Hashable, Identifiable {
    let id: Int
    let name: String
}

extension API {
    private func ok(_ method: String, _ path: String, body: Any? = nil) async throws {
        let (data, status) = try await send(method, path, body: body)
        guard (200..<300).contains(status) else { throw Self.error(data, status) }
    }

    private func query(_ q: String) -> String {
        q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    func agentInfo(_ id: String) async throws -> AgentInfo {
        try await json(AgentInfo.self, "GET", "/api/agents/\(id)/")
    }

    func agentTools(_ id: String) async throws -> AgentTools {
        try await json(AgentTools.self, "GET", "/api/agents/\(id)/tools/")
    }

    func runtimeAgents() async throws -> [RuntimeAgent] {
        try await json([RuntimeAgent].self, "GET", "/api/agents/runtimes/")
    }

    func runtimeAgent(_ id: String) async throws -> RuntimeAgent {
        try await json(RuntimeAgent.self, "GET", "/api/agents/runtimes/\(id)/")
    }

    func runtimeAgentBases() async throws -> [RuntimeAgentBase] {
        try await json([RuntimeAgentBase].self, "GET", "/api/agents/runtimes/bases/")
    }

    func runtimeAgentTools() async throws -> [RuntimeAgentToolOption] {
        try await json([RuntimeAgentToolOption].self, "GET", "/api/agents/runtimes/tools/")
    }

    func integrations() async throws -> [IntegrationOption] {
        try await json([IntegrationOption].self, "GET", "/api/integrations/")
    }

    func memories() async throws -> [MemoryOption] {
        try await json([MemoryOption].self, "GET", "/api/memories/")
    }

    func createRuntimeAgent(_ body: [String: Any]) async throws -> RuntimeAgent {
        try await json(RuntimeAgent.self, "POST", "/api/agents/runtimes/", body: body)
    }

    func updateRuntimeAgent(_ id: String, _ body: [String: Any]) async throws -> RuntimeAgent {
        try await json(RuntimeAgent.self, "PATCH", "/api/agents/runtimes/\(id)/", body: body)
    }

    func deleteRuntimeAgent(_ id: String) async throws {
        try await ok("DELETE", "/api/agents/runtimes/\(id)/")
    }

    func agentUsers(_ id: String) async throws -> [AgentUserAccess] {
        try await json([AgentUserAccess].self, "GET", "/api/agents/runtimes/\(id)/users/")
    }

    func agentGroups(_ id: String) async throws -> [AgentGroupAccess] {
        try await json([AgentGroupAccess].self, "GET", "/api/agents/runtimes/\(id)/groups/")
    }

    func addAgentUser(_ id: String, user: String, canManage: Bool) async throws {
        try await ok("POST", "/api/agents/runtimes/\(id)/users/", body: ["user_id": user, "can_manage": canManage])
    }

    func updateAgentUser(_ id: String, user: String, canManage: Bool) async throws {
        try await ok("PATCH", "/api/agents/runtimes/\(id)/users/\(user)/", body: ["can_manage": canManage])
    }

    func removeAgentUser(_ id: String, user: String) async throws {
        try await ok("DELETE", "/api/agents/runtimes/\(id)/users/\(user)/")
    }

    func addAgentGroup(_ id: String, group: Int, canManage: Bool) async throws {
        try await ok("POST", "/api/agents/runtimes/\(id)/groups/", body: ["group_id": group, "can_manage": canManage])
    }

    func removeAgentGroup(_ id: String, group: Int) async throws {
        try await ok("DELETE", "/api/agents/runtimes/\(id)/groups/\(group)/")
    }

    func searchUsers(_ q: String) async throws -> [UserOption] {
        try await json([UserOption].self, "GET", "/api/users/?q=\(query(q))&limit=10")
    }

    func searchGroups(_ q: String) async throws -> [GroupOption] {
        try await json([GroupOption].self, "GET", "/api/accounts/groups/?q=\(query(q))&limit=10")
    }
}
