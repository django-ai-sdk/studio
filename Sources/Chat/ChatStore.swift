import Foundation

/// State of the open chat. Views read it; the composer and message views call its methods.
@Observable @MainActor
final class ChatStore {
    let app: AppStore
    var threadID: String?
    var agentID: String?
    var messages: [ChatMessage] = []
    var streaming = false
    var loading = false
    var error: String?
    /// Text of a message that could not be sent (thread creation failed, or Stop before it went
    /// out); the composer puts it back in its field and sets this to nil.
    var restoredDraft: String?
    /// The open thread whose history failed to load; `retry()` loads it again.
    private(set) var failedThreadID: String?

    var canRetry: Bool { failedThreadID != nil && failedThreadID == threadID }

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped per send and by `stop()`: a stream task only touches state while it still owns it.
    @ObservationIgnored private var generation = 0
    /// Bumped whenever another chat is shown: work started for the previous one must not land here.
    @ObservationIgnored private var session = 0
    /// Thread creation in flight, shared by concurrent `ensureThread()` callers (send + uploads).
    @ObservationIgnored private var creating: Task<String, Error>?
    /// The optimistic user message until the request goes out (removed again if it never does).
    @ObservationIgnored private var unsent: (id: String, text: String)?
    /// The streaming reply, ahead of `messages`: events fold in here and are published throttled.
    @ObservationIgnored private var reply: ChatMessage?
    @ObservationIgnored private var lastPublish: ContinuousClock.Instant?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// ~20 view updates per second while streaming; finish/abort/error publish at once.
    private static let publishInterval = Duration.milliseconds(50)

    init(app: AppStore) { self.app = app }

    var api: API { app.api }
    var agent: Agent? { app.agents.first { $0.id == agentID } }

    func newChat(agent: String? = nil) {
        stop()
        session &+= 1
        creating = nil
        threadID = nil
        messages = []
        error = nil
        restoredDraft = nil
        failedThreadID = nil
        agentID = agent ?? agentID ?? app.agents.first?.id
    }

    func open(_ id: String) async {
        guard id != threadID || failedThreadID == id else { return }
        stop()
        session &+= 1
        let session = session
        creating = nil
        threadID = id
        messages = []
        error = nil
        restoredDraft = nil
        failedThreadID = nil
        if let thread = app.threads.first(where: { $0.id == id }) { agentID = thread.agent_id }
        loading = true
        do {
            let history = try await api.history(thread: id)
            guard self.session == session else { return }
            messages = history
            loading = false
        } catch {
            // A newer open/newChat owns `loading` now.
            guard self.session == session else { return }
            loading = false
            // Keep the thread selected, but let open(id) / retry() load it again.
            failedThreadID = id
            if !Self.isCancellation(error) { self.error = error.localizedDescription }
        }
    }

    /// Loads the open thread again after its history failed to load.
    func retry() async {
        guard let id = failedThreadID, id == threadID else { return }
        await open(id)
    }

    /// The open thread's id, creating the thread first for a new chat (uploads need one).
    func ensureThread() async throws -> String {
        if let threadID { return threadID }
        let session = session
        let creation: Task<String, Error>
        if let creating {
            creation = creating
        } else {
            let agent = agentID
            creation = Task { try await self.api.createThread(agent: agent) }
            creating = creation
        }
        defer { if creating == creation { creating = nil } }
        let id = try await creation.value
        // Stopped, or another chat was opened meanwhile: don't hijack its navigation.
        try Task.checkCancellation()
        guard self.session == session else { throw CancellationError() }
        if let threadID { return threadID }
        threadID = id
        app.route = .thread(id)
        return id
    }

    /// Sends a user message. `attachments` are extra UIMessage parts, e.g. `{"type":"file",…}`.
    func send(_ text: String, attachments: [JSON] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, !streaming else { return }
        generation &+= 1
        let token = generation
        streaming = true
        error = nil
        restoredDraft = nil
        var parts = attachments
        if !text.isEmpty { parts.append(.object(["type": .string("text"), "text": .string(text)])) }
        // Shown at once; removed again (text back in the composer) if it can't be sent.
        let userMessage = ChatMessage(id: UUID().uuidString, role: "user", parts: parts)
        messages.append(userMessage)
        unsent = (userMessage.id, text)
        task = Task {
            defer {
                if generation == token { streaming = false; task = nil }
            }
            do {
                let thread = try await ensureThread()
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                unsent = nil
                let history = messages
                let reply = ChatMessage(id: UUID().uuidString, role: "assistant", parts: [])
                messages.append(reply)
                self.reply = reply
                lastPublish = nil
                try await api.chat(thread: thread, agent: agentID, messages: history) { event in
                    try self.receive(event, token: token)
                }
                guard generation == token else { return }
                // The stream ended without `finish`: still close open parts.
                closeReply(.object(["type": .string("finish")]))
                try? await app.refreshThreads()
            } catch {
                // stop() / another chat already closed the reply.
                guard generation == token else { return }
                if unsent != nil { unsend() }
                closeReply(.object(["type": .string("abort")]))
                if !Self.isCancellation(error) { self.error = error.localizedDescription }
            }
        }
    }

    /// Stops the reply: it ends at once with "Stopped"; a message not sent yet goes back to the composer.
    func stop() {
        task?.cancel()
        task = nil
        generation &+= 1
        if unsent != nil { unsend() }
        closeReply(.object(["type": .string("abort")]))
        streaming = false
    }

    // MARK: Streaming

    private func receive(_ event: JSON, token: Int) throws {
        guard generation == token else { throw CancellationError() }
        guard reply != nil else { return }
        try StreamReducer.apply(event, to: &reply!)
        switch event["type"]?.string {
        case "finish", "abort": closeReply(nil)
        case "error": publishReply()
        default: schedulePublish()
        }
    }

    /// Publishes now if the last publish is old enough, else once the interval has passed.
    private func schedulePublish() {
        guard let last = lastPublish, ContinuousClock.now - last < Self.publishInterval else {
            publishReply()
            return
        }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.publishInterval)
            guard !Task.isCancelled else { return }
            self?.publishReply()
        }
    }

    private func publishReply() {
        flushTask?.cancel()
        flushTask = nil
        lastPublish = .now
        guard let reply, let i = messages.lastIndex(where: { $0.id == reply.id }) else { return }
        if messages[i] != reply { messages[i] = reply }
    }

    /// Applies a closing event (if any) to the streaming reply, publishes it and lets it go.
    private func closeReply(_ event: JSON?) {
        guard reply != nil else { return }
        if let event { try? StreamReducer.apply(event, to: &reply!) }
        publishReply()
        reply = nil
        lastPublish = nil
    }

    /// Takes the optimistic user message back out and returns its text to the composer.
    private func unsend() {
        guard let unsent else { return }
        self.unsent = nil
        guard let i = messages.lastIndex(where: { $0.id == unsent.id }) else { return }
        messages.remove(at: i)
        if !unsent.text.isEmpty { restoredDraft = unsent.text }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
