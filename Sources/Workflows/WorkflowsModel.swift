import Foundation
import Observation

@Observable @MainActor
final class WorkflowsModel {
    @ObservationIgnored weak var store: AppStore?
    private var api: API? { store?.api }
    var workflows: [WorkflowItem] = []
    var loaded = false
    var selectedID: String? {
        didSet { if selectedID != oldValue { runs = []; selectedRunID = nil; run = nil } }
    }
    var runs: [WorkflowRun] = []
    var selectedRunID: String? {
        didSet { if selectedRunID != oldValue { run = runs.first { $0.id == selectedRunID } } }
    }
    var run: WorkflowRun?
    var pollGeneration = 0
    var busy = false
    var error: String?

    var selected: WorkflowItem? { workflows.first { $0.id == selectedID } }

    private func attempt(_ work: (API) async throws -> Void) async {
        guard let api else { return }
        do { try await work(api) } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func load() async {
        await attempt { api in
            workflows = try await api.workflows()
            error = nil
            loaded = true
            if selectedID == nil || selected == nil { selectedID = workflows.first?.id }
        }
        loaded = true
    }

    func refresh() async {
        error = nil
        await load()
        await loadRuns()
        pollGeneration += 1
    }

    func loadRuns() async {
        guard let id = selectedID else { return }
        await attempt { api in
            let fresh = try await api.workflowRuns(workflow: id)
            guard selectedID == id else { return }
            runs = fresh
        }
    }

    func start(_ workflow: WorkflowItem, inputs: [String: JSON]) async {
        busy = true
        defer { busy = false }
        await attempt { api in
            let ref = try await api.startWorkflow(key: workflow.slug, inputs: inputs)
            await loadRuns()
            selectedRunID = ref.run_id
            pollGeneration += 1
        }
    }

    func follow(_ id: String) async {
        while !Task.isCancelled {
            guard let api else { return }
            do {
                let fresh = try await api.workflowRun(id)
                guard selectedRunID == id, !Task.isCancelled else { return }
                run = fresh
                if let i = runs.firstIndex(where: { $0.id == id }) { runs[i] = fresh }
                guard let wait = fresh.pollInterval else { return }
                try await Task.sleep(for: wait)
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
                return
            }
        }
    }

    func cancel(_ id: String) async {
        await attempt { api in _ = try await api.cancelWorkflowRun(id) }
        pollGeneration += 1
    }

    func resume(_ id: String) async {
        await attempt { api in _ = try await api.resumeWorkflowRun(id) }
        pollGeneration += 1
    }

    func decide(_ id: String, step: String, approved: Bool) async {
        await attempt { api in _ = try await api.decideWorkflowStep(run: id, step: step, approved: approved) }
        pollGeneration += 1
    }
}

