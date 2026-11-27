import Foundation

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Agent: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let model: String?
    let file_upload: Bool?
    let rag: Bool?
    let vision: Bool?
}

struct ThreadItem: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let agent_id: String
    let updated_at: String

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled" : t
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let role: String
    var parts: [JSON]
    var meta: JSON? = nil

    var text: String { parts.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined() }

    var wire: [String: Any] { ["id": id, "role": role, "parts": parts.map(\.any)] }
}

final class API: Sendable {
    let base: URL
    let session: URLSession

    init(base: URL) {
        self.base = base
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpCookieAcceptPolicy = .always
        session = URLSession(configuration: config)
    }

    private var cookies: [HTTPCookie] { HTTPCookieStorage.shared.cookies(for: base) ?? [] }

    func url(_ path: String) -> URL? { URL(string: path, relativeTo: base) }

    func request(_ method: String, _ path: String, body: Any? = nil) throws -> URLRequest {
        guard let url = url(path) else { throw APIError(message: "Bad URL: \(path)") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let csrf = cookies.first(where: { $0.name == "csrftoken" })?.value {
            req.setValue(csrf, forHTTPHeaderField: "X-CSRFToken")
        }
        req.setValue(base.absoluteString, forHTTPHeaderField: "Referer")
        if let data = body as? Data {
            req.httpBody = data
        } else if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    @discardableResult
    func send(_ req: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    @discardableResult
    func send(_ method: String, _ path: String, body: Any? = nil) async throws -> (Data, Int) {
        try await send(request(method, path, body: body))
    }

    func json<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, body: Any? = nil) async throws -> T {
        try await json(type, request(method, path, body: body))
    }

    func json<T: Decodable>(_ type: T.Type, _ req: URLRequest) async throws -> T {
        let (data, status) = try await send(req)
        guard (200..<300).contains(status) else { throw Self.error(data, status) }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw APIError(message: "Unexpected response from \(req.url?.path ?? "server"): \(error)")
        }
    }

    static func error(_ data: Data, _ status: Int) -> APIError {
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let first = (obj?["errors"] as? [[String: Any]])?.first?["message"] as? String
        return APIError(message: first ?? obj?["detail"] as? String ?? obj?["message"] as? String ?? "HTTP \(status)")
    }

    func stream(_ path: String, body: Any, onEvent: @MainActor @Sendable (JSON) throws -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request("POST", path, body: body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw Self.error(data, status)
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { break }
            guard let event = try? JSONDecoder().decode(JSON.self, from: Data(payload.utf8)) else { continue }
            try await onEvent(event)
        }
    }

    private let auth = "/_allauth/browser/v1"

    func isLoggedIn() async throws -> Bool {
        try await session() != nil
    }

    func session() async throws -> String? {
        let (data, status) = try await send("GET", "\(auth)/auth/session")
        guard status == 200 else { return nil }
        let user = (try? JSONDecoder().decode(JSON.self, from: data))?["data"]?["user"]
        return user?["email"]?.string ?? user?["display"]?.string ?? ""
    }

    func login(email: String, password: String) async throws {
        _ = try await isLoggedIn()
        let (data, status) = try await send("POST", "\(auth)/auth/login", body: ["email": email, "password": password])
        if status == 200 || status == 409 { return }
        if status == 401 {
            throw APIError(message: "Login needs another step (e.g. email verification). Finish it in the web app first.")
        }
        throw Self.error(data, status)
    }

    func logout() async {
        _ = try? await send("DELETE", "\(auth)/auth/session")
        cookies.forEach(HTTPCookieStorage.shared.deleteCookie)
    }

    func agents() async throws -> [Agent] {
        struct R: Decodable { let agents: [Agent] }
        return try await json(R.self, "GET", "/api/agents/").agents
    }

    func threads() async throws -> [ThreadItem] {
        struct R: Decodable { let threads: [ThreadItem] }
        return try await json(R.self, "GET", "/api/threads/").threads
    }

    func history(thread: String) async throws -> [ChatMessage] {
        struct R: Decodable { let messages: [JSON] }
        return try await json(R.self, "GET", "/api/threads/\(thread)/").messages.map {
            ChatMessage(id: $0["id"]?.string ?? UUID().uuidString, role: $0["role"]?.string ?? "assistant",
                        parts: $0["parts"]?.array ?? [], meta: $0)
        }
    }

    func createThread(agent: String?) async throws -> String {
        struct R: Decodable { let thread_id: String? }
        let body: [String: Any] = ["messages": [], "agent_id": agent ?? NSNull()]
        guard let id = try await json(R.self, "POST", "/api/threads/", body: body).thread_id else {
            throw APIError(message: "Server did not return a thread id")
        }
        return id
    }

    func deleteThread(_ id: String) async throws {
        let (data, status) = try await send("DELETE", "/api/threads/\(id)/")
        guard (200..<300).contains(status) else { throw Self.error(data, status) }
    }

    func chat(thread: String, agent: String?, messages: [ChatMessage], onEvent: @MainActor @Sendable (JSON) throws -> Void) async throws {
        let body: [String: Any] = [
            "id": thread,
            "trigger": "submit-message",
            "agent_id": agent ?? NSNull(),
            "messages": messages.map(\.wire),
        ]
        try await stream("/api/threads/\(thread)/", body: body, onEvent: onEvent)
    }
}
