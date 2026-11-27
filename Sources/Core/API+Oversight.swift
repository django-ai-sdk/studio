import Foundation

struct OversightTurn: Decodable, Identifiable, Hashable {
    let id: String
    let created_at: String
    let status: String
    let channel: String?
    let agent_name: String?
    let policy: String?
    let outcome: String
    let report_outcome: String?
    let severity: String?
    let matches: [OversightMatch]?
    let model: String?
    let tokens: Int?
    let cost: Double?
    let latency_ms: Double?
    let reviews_open: Int?
    let reflected: Bool?
    let preview: String?
    let content: JSON?
    let content_state: String?
    let answers: [OversightAnswer]?
    let reviews: [OversightReview]?
    let error: String?
    let reflect_state: String?
    let thread_id: String?
    let message_id: String?

    var isDetail: Bool { answers != nil }
    var closed: Bool { status == "closed" }
    var reflecting: Bool { ["pending", "running"].contains(reflect_state ?? "") }
    var createdAt: Date? { OversightDate.parse(created_at) }
}

struct OversightMatch: Decodable, Identifiable, Hashable {
    let id: String
    let rule: String
    let stage: String
    let mode: String
    let acted: Bool
    let actions: [JSON]?
    let condition: JSON?
    let created_at: String?

    var actionKinds: [String] { (actions ?? []).compactMap { $0["kind"]?.string } }
}

struct OversightAnswer: Decodable, Identifiable, Hashable {
    let id: String
    let lens: String
    let label: String?
    let kind: String?
    let stage: String
    let answerer: String
    let model: String?
    let value: JSON?
    let confidence: Double?
    let error: String?
    let cost: Double?
    let latency_ms: Double?
    let created_at: String?
    let trail: [JSON]?
    let rationale: String?
    let spans: [JSON]?
    let items: [String: Double]?
}

struct OversightReview: Decodable, Identifiable, Hashable {
    let id: String
    let turn_id: String
    let queue: String
    let rule: String?
    let status: String
    let created_at: String
    let resolved_by: String?
    let agree: Bool?
    let note: String?
}

enum OversightUnavailable: Error, Equatable {
    case notEnabled
    case forbidden(String)
}

enum OversightDate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    static func parse(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        return (try? fractional.parse(iso)) ?? (try? plain.parse(iso))
    }
}

extension API {
    func oversightTurns(thread: String, limit: Int = 100) async throws -> [OversightTurn] {
        struct Page: Decodable { let items: [OversightTurn] }
        let path = "/api/oversight/turns/?thread_id=\(thread.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? thread)&limit=\(limit)"
        let (data, status) = try await send("GET", path)
        switch status {
        case 200..<300: break
        case 404: throw OversightUnavailable.notEnabled
        case 401, 403: throw OversightUnavailable.forbidden(Self.error(data, status).message)
        default: throw Self.error(data, status)
        }
        do { return try JSONDecoder().decode(Page.self, from: data).items } catch {
            throw APIError(message: "Unexpected oversight response: \(error)")
        }
    }

    func oversightTurn(_ id: String) async throws -> OversightTurn {
        try await json(OversightTurn.self, "GET", "/api/oversight/turns/\(id)/")
    }
}
