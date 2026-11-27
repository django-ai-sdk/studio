import SwiftUI

@Observable @MainActor
final class ThreadActions {
    var renaming = false
    var title = ""
    var confirmingDelete = false
    var reindexing = false
    var notice: String?

    func beginRename(_ app: AppStore, threadID: String) {
        title = app.threads.first { $0.id == threadID }?.title ?? ""
        renaming = true
    }

    func rename(_ app: AppStore, threadID: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            try await app.api.renameThread(threadID, title: title)
            try? await app.refreshThreads()
        } catch {
            notice = "Couldn’t rename the thread: \(error.localizedDescription)"
        }
    }

    func reindex(_ app: AppStore, agent: String?, threadID: String, force: Bool) async {
        guard let agent, !reindexing else { return }
        reindexing = true
        defer { reindexing = false }
        let memory = try? await app.api.threadMemories(threadID).first?.id
        do {
            try await app.api.reindexAgent(agent, memory: memory, force: force)
            notice = force ? "The knowledge index was rebuilt." : "The knowledge index was refreshed."
        } catch {
            notice = "Reindexing failed: \(error.localizedDescription)"
        }
    }
}

extension View {
    func threadActionDialogs(_ actions: ThreadActions, threadID: String?) -> some View {
        modifier(ThreadActionDialogs(actions: actions, threadID: threadID))
    }
}

private struct ThreadActionDialogs: ViewModifier {
    @Bindable var actions: ThreadActions
    let threadID: String?
    @Environment(AppStore.self) private var app

    func body(content: Content) -> some View {
        content
            .alert("Rename Thread", isPresented: $actions.renaming) {
                TextField("Title", text: $actions.title)
                Button("Rename") {
                    if let threadID { Task { await actions.rename(app, threadID: threadID) } }
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete this thread?", isPresented: $actions.confirmingDelete) {
                Button("Delete Thread", role: .destructive) {
                    if let threadID { Task { await app.delete(thread: threadID) } }
                }
            } message: {
                Text("Its messages and files are removed. This can’t be undone.")
            }
            .alert(actions.notice ?? "", isPresented: Binding(get: { actions.notice != nil },
                                                               set: { if !$0 { actions.notice = nil } })) {
                Button("OK") {}
            }
    }
}

struct ThreadActionsMenu: View {
    let threadID: String

    @Environment(AppStore.self) private var app
    @Environment(ChatStore.self) private var chat
    @State private var actions = ThreadActions()

    var body: some View {
        Menu {
            Button("Rename…", systemImage: "pencil") { actions.beginRename(app, threadID: threadID) }
            Divider()
            Button("Reindex Knowledge", systemImage: "arrow.clockwise") {
                Task { await actions.reindex(app, agent: chat.agentID, threadID: threadID, force: false) }
            }
            .disabled(chat.agent?.rag != true || actions.reindexing)
            Button("Rebuild Knowledge Index", systemImage: "bolt") {
                Task { await actions.reindex(app, agent: chat.agentID, threadID: threadID, force: true) }
            }
            .disabled(chat.agent?.rag != true || actions.reindexing)
            Divider()
            Button("Delete Thread…", systemImage: "trash", role: .destructive) { actions.confirmingDelete = true }
        } label: {
            Label("Thread Actions", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("Thread actions")
        .threadActionDialogs(actions, threadID: threadID)
    }
}

struct ThreadActionButtons: View {
    let threadID: String

    @Environment(AppStore.self) private var app
    @Environment(ChatStore.self) private var chat
    @State private var actions = ThreadActions()

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Reindex", systemImage: "arrow.clockwise") {
                    Task { await actions.reindex(app, agent: chat.agentID, threadID: threadID, force: false) }
                }
                Button("Rebuild (Force)", systemImage: "bolt") {
                    Task { await actions.reindex(app, agent: chat.agentID, threadID: threadID, force: true) }
                }
            } label: {
                if actions.reindexing {
                    Label { Text("Reindexing…") } icon: { ProgressView().controlSize(.small) }
                } else {
                    Label("Reindex Knowledge", systemImage: "arrow.clockwise")
                }
            }
            .fixedSize()
            .disabled(chat.agent?.rag != true || actions.reindexing)
            .help(chat.agent?.rag == true ? "Refresh the agent's knowledge index" : "This agent has no knowledge to index")

            Button("Rename…", systemImage: "pencil") { actions.beginRename(app, threadID: threadID) }
            Spacer(minLength: 0)
            Button("Delete…", systemImage: "trash", role: .destructive) { actions.confirmingDelete = true }
                .foregroundStyle(.red)
        }
        .labelStyle(.titleAndIcon)
        .threadActionDialogs(actions, threadID: threadID)
    }
}
