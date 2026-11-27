import Foundation

@Observable @MainActor
final class InsightsModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case unavailable(OversightUnavailable)
        case failed(String)
    }

    private(set) var threadID: String?
    private(set) var phase: Phase = .idle
    private(set) var turns: [OversightTurn] = []
    private(set) var details: [String: OversightTurn] = [:]
    private(set) var detailErrors: [String: String] = [:]
    var expanded: Set<String> = []
    private var autoOpened: String?

    var numbers: [String: Int] {
        Dictionary(uniqueKeysWithValues: turns.reversed().enumerated().map { ($1.id, $0 + 1) })
    }

    var toReview: Int { turns.reduce(0) { $0 + ($1.reviews_open ?? 0) } }

    private var expectedCount: Int?

    var isSettling: Bool {
        if let expectedCount, turns.count < expectedCount { return true }
        return turns.contains { !$0.closed } || details.values.contains { !$0.closed || $0.reflecting }
    }

    func expectNewTurn() { expectedCount = turns.count + 1 }

    func load(api: API, thread: String?) async {
        if thread != threadID {
            threadID = thread
            turns = []; details = [:]; detailErrors = [:]; expanded = []; autoOpened = nil; expectedCount = nil
            phase = thread == nil ? .idle : .loading
        }
        guard let thread else { return }
        do {
            let rows = try await api.oversightTurns(thread: thread)
            guard thread == threadID else { return }
            turns = rows
            phase = .loaded
            if let expected = expectedCount, rows.count >= expected { expectedCount = nil }
            if let newest = rows.first?.id, newest != autoOpened {
                autoOpened = newest
                expanded.insert(newest)
            }
            for id in expanded where rows.contains(where: { $0.id == id }) {
                await loadDetail(api: api, id: id, force: true)
            }
        } catch let error as OversightUnavailable {
            if thread == threadID { phase = .unavailable(error) }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            if thread == threadID, turns.isEmpty { phase = .failed(error.localizedDescription) }
        }
    }

    func loadDetail(api: API, id: String, force: Bool = false) async {
        guard force || details[id] == nil else { return }
        do {
            let turn = try await api.oversightTurn(id)
            details[id] = turn
            detailErrors[id] = nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            if details[id] == nil { detailErrors[id] = error.localizedDescription }
        }
    }

    func follow(api: API, thread: String?) async {
        for _ in 0..<20 {
            guard isSettling, thread == threadID else { return }
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { return }
            await load(api: api, thread: thread)
        }
        if !Task.isCancelled { expectedCount = nil }
    }
}
