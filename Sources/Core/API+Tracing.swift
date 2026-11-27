import Foundation

/// One recorded span (`TraceOut`): an agent run, step, LLM call, tool call, pipeline component…
/// `tags` keep Haystack's raw attributes (`haystack.tool.name`, `haystack.tool.error`, …).
struct TraceSpanOut: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let operation_name: String
    let started_at: String
    let ended_at: String?
    let duration_ms: Double?
    let parent_id: String?
    let thread_id: String?
    let message_id: String?
    let agent_id: String?
    let agent_name: String?
    let model_name: String?
    let prompt_tokens: Int?
    let completion_tokens: Int?
    let total_tokens: Int?
    let tags: [String: JSON]?
}

/// Token totals over a set of spans, with a breakdown per subagent id.
struct TraceTokenUsage: Decodable, Hashable, Sendable {
    var prompt_tokens: Int?
    var completion_tokens: Int?
    var total_tokens: Int?
    var agent_name: String?
    var by_subagent: [String: TraceTokenUsage]?
}

/// The cost-bearing fields of an oversight turn record (`TurnOut`); only present when the
/// backend mounts the oversight API.
struct TraceTurnCost: Decodable, Hashable, Sendable {
    let id: String
    let created_at: String
    let cost: Double?
    let tokens: Int?
    let latency_ms: Double?
    let model: String?
}

extension API {
    /// Every span of a thread. The endpoint pages by 100 (newest first), so keep asking until a
    /// short page; `maxPages` bounds very long threads.
    func threadTraces(thread: String, maxPages: Int = 20) async throws -> [TraceSpanOut] {
        struct R: Decodable { let traces: [TraceSpanOut] }
        let limit = 100
        var all: [TraceSpanOut] = []
        for page in 0..<maxPages {
            let batch = try await json(R.self, "GET", "/api/threads/\(thread)/traces/?limit=\(limit)&offset=\(page * limit)").traces
            all += batch
            if batch.count < limit { break }
        }
        return all
    }

    func messageTraces(message: String) async throws -> [TraceSpanOut] {
        struct R: Decodable { let traces: [TraceSpanOut] }
        return try await json(R.self, "GET", "/api/messages/\(message)/traces/?limit=100").traces
    }

    func threadTokens(thread: String) async throws -> TraceTokenUsage {
        try await json(TraceTokenUsage.self, "GET", "/api/threads/\(thread)/tokens/")
    }

    func messageTokens(message: String) async throws -> TraceTokenUsage {
        try await json(TraceTokenUsage.self, "GET", "/api/messages/\(message)/tokens/")
    }

    /// Per-turn cost from the oversight feed. Returns nil when oversight isn't mounted (404) or fails.
    func threadTurnCosts(thread: String) async -> [TraceTurnCost]? {
        struct R: Decodable { let items: [TraceTurnCost] }
        return try? await json(R.self, "GET", "/api/oversight/turns/?thread_id=\(thread)&limit=100").items
    }
}
