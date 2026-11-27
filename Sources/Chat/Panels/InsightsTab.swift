import SwiftUI

/// Insights tab of the thread panel: for each answer in the thread, what oversight
/// made of it (web: thread-panel/InsightsTab.tsx). The newest turn is open with its
/// pipeline; earlier turns are one line each and load their record when opened.
struct InsightsTab: View {
    let threadID: String?

    @Environment(AppStore.self) private var store
    @Environment(ChatStore.self) private var chat
    @State private var model = InsightsModel()
    /// Bumped to reload: after a reply finishes streaming, or from the refresh button.
    @State private var generation = 0

    private struct LoadKey: Hashable { let thread: String?; let generation: Int }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: LoadKey(thread: threadID, generation: generation)) {
                await model.load(api: store.api, thread: threadID)
                await model.follow(api: store.api, thread: threadID)
            }
            .onChange(of: chat.streaming) { was, now in
                guard was, !now, chat.threadID == threadID else { return }
                model.expectNewTurn()
                generation += 1
            }
    }

    @ViewBuilder private var content: some View {
        if threadID == nil {
            ContentUnavailableView("No Checks Yet", systemImage: "checkmark.shield",
                                   description: Text("Each answer’s oversight checks show up here once you send a message."))
        } else {
            switch model.phase {
            case .idle, .loading:
                ProgressView().controlSize(.small)
            case .unavailable(.notEnabled):
                ContentUnavailableView("Oversight Is Off", systemImage: "shield.slash",
                                       description: Text("This server doesn’t expose the oversight API, so there are no checks to show."))
            case .unavailable(.forbidden):
                ContentUnavailableView("Checks Are Shown to Overseers", systemImage: "lock.shield",
                                       description: Text("Ask an admin if you need to see how answers in this thread were checked."))
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn’t Load Checks", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { generation += 1 }
                }
            case .loaded where model.turns.isEmpty:
                ContentUnavailableView("Nothing Was Checked", systemImage: "checkmark.shield",
                                       description: Text(model.isSettling
                                           ? "Checking the latest answer…"
                                           : "No oversight policy ran on the answers in this thread."))
            case .loaded:
                InsightsList(model: model, api: store.api) { generation += 1 }
            }
        }
    }
}

/// The thread's turns as cards, newest first.
private struct InsightsList: View {
    let model: InsightsModel
    let api: API
    let refresh: () -> Void

    var body: some View {
        let numbers = model.numbers
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                header
                ForEach(model.turns) { row in
                    OversightTurnCard(
                        row: row,
                        number: numbers[row.id],
                        detail: model.details[row.id],
                        detailError: model.detailErrors[row.id],
                        isExpanded: Binding(
                            get: { model.expanded.contains(row.id) },
                            set: { open in
                                if open { model.expanded.insert(row.id) } else { model.expanded.remove(row.id) }
                            }),
                        loadDetail: { await model.loadDetail(api: api, id: row.id) },
                        retryDetail: { Task { await model.loadDetail(api: api, id: row.id, force: true) } }
                    )
                }
            }
            .padding(16)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("This Thread").font(.headline)
            Text(OversightFormat.plural(model.turns.count, "turn"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if model.toReview > 0 {
                OversightBadge(tone: .init(label: "\(model.toReview) to review", symbol: "person.badge.clock", color: .purple))
            }
            Spacer(minLength: 0)
            if model.isSettling {
                ProgressView().controlSize(.mini).help("Checks are still running")
            }
            Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Reload checks")
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }
}
