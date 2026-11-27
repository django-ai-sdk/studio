import Foundation

/// The Insights tab's data: a thread's oversight turns, and the full record of
/// every turn that has been opened. Owned by `InsightsTab` as plain `@State`.
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
    /// Newest first, like the API.
    private(set) var turns: [OversightTurn] = []
    private(set) var details: [String: OversightTurn] = [:]
    private(set) var detailErrors: [String: String] = [:]
    /// Open turn cards. The newest turn opens by itself when it shows up.
    var expanded: Set<String> = []
    private var autoOpened: String?

    /// Turn number by id, counting from the thread's first turn.
    var numbers: [String: Int] {
        Dictionary(uniqueKeysWithValues: turns.reversed().enumerated().map { ($1.id, $0 + 1) })
    }

    var toReview: Int { turns.reduce(0) { $0 + ($1.reviews_open ?? 0) } }

    /// Set when a reply finished streaming: its turn may be recorded a moment later.
    private var expectedCount: Int?

    /// A turn or its background lenses are still running, so the records will change.
    var isSettling: Bool {
        if let expectedCount, turns.count < expectedCount { return true }
        return turns.contains { !$0.closed } || details.values.contains { !$0.closed || $0.reflecting }
    }

    /// A reply just finished: expect one more turn than now.
    func expectNewTurn() { expectedCount = turns.count + 1 }

    /// Loads the thread's turns (again) and refreshes the records already opened.
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
            // Open cards follow the list; reload their records.
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

    /// Polls while turns settle: the record is written as the stream ends and the
    /// lenses that run afterwards land seconds later (web: useMessageTurn, 3 s × 20).
    func follow(api: API, thread: String?) async {
        for _ in 0..<20 {
            guard isSettling, thread == threadID else { return }
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { return }
            await load(api: api, thread: thread)
        }
        if !Task.isCancelled { expectedCount = nil }  // gave up waiting
    }
}
