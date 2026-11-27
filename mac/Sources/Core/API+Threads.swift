import Foundation

struct ThreadTokenUsage: Decodable, Hashable {
    var prompt_tokens = 0
    var completion_tokens = 0
    var total_tokens = 0
}

struct ThreadFileMeta: Decodable, Hashable {
    var file_count = 0
}

struct ThreadSource: Decodable, Hashable, Identifiable {
    let key: String
    let title: String
    let kind: String
    let content: String
    let url: String?
    let cited: Bool
    var id: String { key }
    var isWeb: Bool { kind == "web" }
    var link: URL? { url.flatMap(URL.init(string:)) }

    private enum CodingKeys: String, CodingKey { case key, title, kind, content, url, cited }

    init(key: String, title: String, kind: String, content: String, url: String?, cited: Bool) {
        (self.key, self.title, self.kind, self.content, self.url, self.cited) = (key, title, kind, content, url, cited)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "document"
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        url = try? c.decode(String.self, forKey: .url)
        cited = (try? c.decode(Bool.self, forKey: .cited)) ?? false
    }
}

struct ThreadMemory: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let document_count: Int?
    let active: Bool?
}

extension API {
    private func expectOK(_ method: String, _ path: String, body: Any? = nil) async throws {
        let (data, status) = try await send(method, path, body: body)
        guard (200..<300).contains(status) else { throw Self.error(data, status) }
    }

    func renameThread(_ id: String, title: String) async throws {
        try await expectOK("PATCH", "/api/threads/\(id)/", body: ["title": title])
    }

    func setThreadAgent(_ id: String, agent: String) async throws {
        try await expectOK("PATCH", "/api/threads/\(id)/", body: ["agent_id": agent])
    }

    func threadTokens(_ id: String) async throws -> ThreadTokenUsage {
        try await json(ThreadTokenUsage.self, "GET", "/api/threads/\(id)/tokens/")
    }

    func threadFileMeta(_ id: String) async throws -> ThreadFileMeta {
        try await json(ThreadFileMeta.self, "GET", "/api/threads/\(id)/file-meta/")
    }

    func threadSources(_ id: String) async throws -> [ThreadSource] {
        struct R: Decodable { let sources: [ThreadSource] }
        return try await json(R.self, "GET", "/api/threads/\(id)/sources/").sources
    }

    func threadMemories(_ id: String) async throws -> [ThreadMemory] {
        try await json([ThreadMemory].self, "GET", "/api/memories/thread/\(id)")
    }

    func reindexAgent(_ agent: String, memory: String? = nil, force: Bool) async throws {
        var path = "/api/agents/\(agent)/reindex/?force_rebuild=\(force)"
        if let memory { path += "&memory_id=\(memory)" }
        try await expectOK("POST", path)
    }
}
