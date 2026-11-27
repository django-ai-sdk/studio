import Foundation

struct WorkflowItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let slug: String
    let definition: JSON
    let active: Bool

    var steps: [JSON] { definition["steps"]?.array ?? [] }

    var inputFields: [(name: String, field: JSON)] {
        (definition["input_fields"]?.object ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var historyInputs: Set<String> {
        Set(steps.flatMap { $0["history"]?.array?.compactMap(\.string) ?? [] })
    }
}

struct StepRun: Decodable, Identifiable, Hashable {
    let id: String
    let sequence: Int
    let step_name: String
    let output: JSON?
    let status: String
    let error: String
    let detail: String?
    let started_at: String?
    let completed_at: String?
}

struct WorkflowRun: Decodable, Identifiable, Hashable {
    let id: String
    let workflow_id: String?
    let workflow_key: String
    let status: String
    let attempt: Int
    let trigger: String?
    let outputs: JSON?
    let error: String
    let created_at: String
    let started_at: String?
    let completed_at: String?
    let steps: [StepRun]?

    var isTerminal: Bool { ["completed", "failed", "cancelled"].contains(status) }
    var isCancellable: Bool { status == "pending" || status == "running" }
    var isResumable: Bool { status == "failed" || status == "cancelled" }
    var waitingSteps: [StepRun] { (steps ?? []).filter { $0.status == "waiting" } }

    var pollInterval: Duration? {
        if isTerminal { return nil }
        let open = (steps ?? []).filter { ["pending", "running", "waiting"].contains($0.status) }
        return !open.isEmpty && open.allSatisfy({ $0.status == "waiting" }) ? .seconds(10) : .seconds(2)
    }
}

struct WorkflowRunRef: Decodable {
    let run_id: String
    let status: String
}

extension API {
    func workflows() async throws -> [WorkflowItem] {
        try await json([WorkflowItem].self, "GET", "/api/workflows/")
    }

    func workflowRuns(workflow id: String, limit: Int = 25) async throws -> [WorkflowRun] {
        try await json([WorkflowRun].self, "GET", "/api/workflows/\(id)/runs/?limit=\(limit)")
    }

    func workflowRun(_ id: String) async throws -> WorkflowRun {
        try await json(WorkflowRun.self, "GET", "/api/workflows/runs/\(id)/")
    }

    func startWorkflow(key: String, inputs: [String: JSON]) async throws -> WorkflowRunRef {
        let key = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        return try await json(WorkflowRunRef.self, "POST", "/api/workflows/\(key)/run/",
                              body: ["inputs": JSON.object(inputs).any])
    }

    func cancelWorkflowRun(_ id: String) async throws -> WorkflowRunRef {
        try await json(WorkflowRunRef.self, "POST", "/api/workflows/runs/\(id)/cancel/")
    }

    func resumeWorkflowRun(_ id: String) async throws -> WorkflowRunRef {
        try await json(WorkflowRunRef.self, "POST", "/api/workflows/runs/\(id)/resume/")
    }

    func decideWorkflowStep(run id: String, step: String, approved: Bool, note: String = "") async throws -> WorkflowRunRef {
        let step = step.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? step
        return try await json(WorkflowRunRef.self, "POST", "/api/workflows/runs/\(id)/steps/\(step)/decision/",
                              body: ["approved": approved, "note": note])
    }
}
