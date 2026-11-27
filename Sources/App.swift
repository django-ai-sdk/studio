#if os(macOS)
import AppKit
#endif
import SwiftUI

@main
struct StudioApp: App {
    @State private var store = AppStore()

    init() {
        #if os(macOS)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApplication.shared.applicationIconImage = StudioAppIcon.image()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup("Studio") {
            RootView()
                .environment(store)
                .environment(store.chat)
                .tint(StudioLogo.brandGreen)
                #if os(macOS)
                .frame(minWidth: 820, minHeight: 520)
                #endif
        }
        .commands {
            SidebarCommands()
            StudioCommands(store: store)
        }
        #if os(macOS)
        Settings {
            SettingsView()
                .environment(store)
                .tint(StudioLogo.brandGreen)
        }
        #endif
    }
}

struct StudioCommands: Commands {
    let store: AppStore
    @FocusedValue(\.threadPanel) private var panel

    private var threadID: String? {
        if case .thread(let id)? = store.route { id } else { nil }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { store.route = .newChat; store.chat.newChat() }
                .keyboardShortcut("n")
                .disabled(store.loggedIn != true)
        }
        CommandGroup(after: .appInfo) {
            Button("Sign Out") { Task { await store.logout() } }
                .disabled(store.loggedIn != true)
        }
        CommandMenu("Chat") {
            Button("Stop Generating") { store.chat.stop() }
                .keyboardShortcut(".")
                .disabled(!store.chat.streaming)
            Divider()
            Button("Rename…") { if let threadID { store.beginRename(threadID) } }
                .disabled(threadID == nil)
            Button("Delete…") { if let threadID { store.confirmDelete(threadID) } }
                .disabled(threadID == nil)
        }
        CommandGroup(after: .sidebar) {
            if let panel {
                Divider()
                ForEach(panel.tabs) { tab in
                    Toggle(tab.title, isOn: Binding(get: { panel.tab == tab }, set: { _ in panel.toggle(tab) }))
                        .keyboardShortcut(tab.shortcut, modifiers: [.command, .option])
                }
            }
        }
    }
}

extension FocusedValues {
    @Entry var threadPanel: ThreadPanelState?
}

enum Route: Hashable {
    case newChat
    case thread(String)
    case agents
    case workflows
}

@Observable @MainActor
final class AppStore {
    static let defaultServer = "http://127.0.0.1:8000"

    private(set) var baseURL: String
    private(set) var api: API
    var loggedIn: Bool?
    var account: String?
    var error: String?
    var agents: [Agent] = []
    var threads: [ThreadItem] = []
    var route: Route? = .newChat
    @ObservationIgnored lazy var chat = ChatStore(app: self)
    let threadActions = ThreadActions()
    var actionThreadID: String?

    init() {
        let stored = UserDefaults.standard.string(forKey: "baseURL") ?? Self.defaultServer
        let url = Self.serverURL(stored) ?? Self.serverURL(Self.defaultServer)
            ?? URL(fileURLWithPath: "/")
        baseURL = url.absoluteString
        api = API(base: url)
    }

    static func serverURL(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host(percentEncoded: false)?.isEmpty == false else { return nil }
        return url
    }

    var serverLabel: String {
        guard let host = api.base.host(percentEncoded: false) else { return baseURL }
        return api.base.port.map { "\(host):\($0)" } ?? host
    }

    @discardableResult
    func applyServer(_ text: String) -> Bool {
        guard let url = Self.serverURL(text) else { return false }
        guard url != api.base else { return true }
        baseURL = url.absoluteString
        UserDefaults.standard.set(baseURL, forKey: "baseURL")
        api = API(base: url)
        if loggedIn == true {
            clearSession()
            loggedIn = nil
            Task { await bootstrap() }
        }
        return true
    }

    private func attempt(_ work: () async throws -> Void) async {
        do { error = nil; try await work() } catch { self.error = error.localizedDescription }
    }

    func bootstrap() async {
        await attempt {
            account = try await api.session()
            loggedIn = account != nil
            if loggedIn == true { try await loadLists() }
        }
        if loggedIn == nil { loggedIn = false }
    }

    func login(email: String, password: String) async {
        await attempt {
            try await api.login(email: email, password: password)
            loggedIn = true
            account = email
            try await loadLists()
        }
    }

    func logout() async {
        await api.logout()
        clearSession()
        loggedIn = false
    }

    private func clearSession() {
        account = nil
        error = nil
        agents = []
        threads = []
        chat.newChat()
        route = .newChat
    }

    func loadLists() async throws {
        async let a = api.agents()
        async let t = api.threads()
        (agents, threads) = try await (a, t)
        if !agents.contains(where: { $0.id == chat.agentID }) { chat.agentID = agents.first?.id }
    }

    func refreshThreads() async throws { threads = try await api.threads() }

    func startChat(agent: String) {
        chat.newChat(agent: agent)
        route = .newChat
    }

    func delete(thread id: String) async {
        await attempt {
            try await api.deleteThread(id)
            threads.removeAll { $0.id == id }
            if chat.threadID == id { chat.newChat(); route = .newChat }
        }
    }

    func beginRename(_ id: String) {
        actionThreadID = id
        threadActions.beginRename(self, threadID: id)
    }

    func confirmDelete(_ id: String) {
        actionThreadID = id
        threadActions.confirmingDelete = true
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            switch store.loggedIn {
            case nil: LaunchView()
            case false?: LoginView()
            case true?: MainView()
            }
        }
        .task { await store.bootstrap() }
    }
}

private struct LaunchView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 20) {
            StudioAppIcon().frame(width: 96, height: 96)
            ProgressView { Text("Connecting to \(store.serverLabel)…") }
                .controlSize(.small)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LoginView: View {
    @Environment(AppStore.self) private var store
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var editingServer = false
    @State private var serverDraft = ""
    @State private var serverInvalid = false
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool { !busy && !email.isEmpty && !password.isEmpty }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    StudioAppIcon().frame(width: 112)
                    VStack(spacing: 6) {
                        Text("Welcome to Studio").font(.title.weight(.semibold))
                        Text("Sign in with your account to continue.")
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 14) {
                    VStack(spacing: 0) {
                        TextField("Email", text: $email, prompt: Text("Email"))
                            .textContentType(.username)
                            #if os(iOS)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            #endif
                            .focused($focus, equals: .email)
                            .onSubmit { focus = .password }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                        Divider().padding(.leading, 12)
                        SecureField("Password", text: $password, prompt: Text("Password"))
                            .textContentType(.password)
                            #if os(iOS)
                            .submitLabel(.go)
                            #endif
                            .focused($focus, equals: .password)
                            .onSubmit(submit)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                    .textFieldStyle(.plain)
                    .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))

                    if let error = store.error {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Button(action: submit) {
                        ZStack {
                            Text("Sign In").opacity(busy ? 0 : 1)
                            if busy { ProgressView().controlSize(.small) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
                }
                #if os(macOS)
                .frame(width: 300)
                #else
                .frame(maxWidth: 340)
                .padding(.horizontal, 24)
                #endif
            }
            Spacer()
            Button {
                serverDraft = store.baseURL
                serverInvalid = false
                editingServer = true
            } label: {
                Label(store.serverLabel, systemImage: "server.rack")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Change server")
            .popover(isPresented: $editingServer, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Server").font(.headline)
                    TextField("Server URL", text: $serverDraft, prompt: Text(AppStore.defaultServer))
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        #endif
                        .frame(width: 260)
                        .onSubmit {
                            serverInvalid = !store.applyServer(serverDraft)
                            if !serverInvalid { editingServer = false }
                        }
                    if serverInvalid {
                        Text("Enter an http:// or https:// address.")
                            .font(.caption).foregroundStyle(.red)
                    } else {
                        Text("The Django backend, not the web app.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .onDisappear { store.applyServer(serverDraft) }
                .presentationCompactAdaptation(.popover)
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RadialGradient(colors: [StudioLogo.brandGreen.opacity(0.18), .clear],
                           center: .init(x: 0.5, y: 0.3), startRadius: 0, endRadius: 420)
                .ignoresSafeArea()
        }
        .animation(.snappy, value: store.error)
        #if os(macOS)
        .onAppear { focus = .email }
        #endif
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        Task { await store.login(email: email, password: password); busy = false }
    }
}

struct MainView: View {
    @Environment(AppStore.self) private var store
    @State private var columns: NavigationSplitViewVisibility = .all
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    #endif

    var body: some View {
        split
            .threadActionDialogs(store.threadActions, threadID: store.actionThreadID)
            .onChange(of: store.route) { _, route in
                switch route {
                case .thread(let id)?: Task { await store.chat.open(id) }
                case .newChat?: if store.chat.threadID != nil { store.chat.newChat() }
                default: break
                }
            }
    }

    private var showsNewChatRow: Bool {
        #if os(iOS)
        sizeClass != .compact
        #else
        true
        #endif
    }

    private var sidebar: some View {
        @Bindable var store = store
        return List(selection: $store.route) {
            Section {
                if showsNewChatRow {
                    Label("New Chat", systemImage: "square.and.pencil").tag(Route.newChat)
                }
                Label("Agents", systemImage: "person.2.badge.gearshape").tag(Route.agents)
                Label("Workflows", systemImage: "flowchart").tag(Route.workflows)
            }
            Section("Chats") {
                ForEach(store.threads) { thread in
                    Text(thread.displayTitle)
                        .lineLimit(1)
                        .tag(Route.thread(thread.id))
                        .contextMenu {
                            Button("Rename…", systemImage: "pencil") { store.beginRename(thread.id) }
                            Divider()
                            Button("Delete…", systemImage: "trash", role: .destructive) {
                                store.confirmDelete(thread.id)
                            }
                        }
                        #if os(iOS)
                        .swipeActions {
                            Button("Delete", systemImage: "trash") { store.confirmDelete(thread.id) }
                                .tint(.red)
                        }
                        #endif
                }
            }
        }
    }

    private var detail: some View {
        Group {
            switch store.route {
            case .agents?: AgentsView()
            case .workflows?: WorkflowsView()
            case .newChat?, .thread?, nil: ChatView()
            }
        }
    }

    #if os(macOS)
    private var split: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        } detail: {
            detail
        }
    }
    #else
    private var split: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            sidebar
                .navigationTitle("Studio")
                .refreshable { try? await store.refreshThreads() }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu("Account", systemImage: "person.crop.circle") {
                            if let account = store.account, !account.isEmpty { Text(account) }
                            Text(store.serverLabel)
                            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                Task { await store.logout() }
                            }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Chat", systemImage: "square.and.pencil") { newChat() }
                    }
                }
        } detail: {
            detail
        }
        .onAppear {
            if sizeClass == .compact && store.route == .newChat && store.chat.threadID == nil { store.route = nil }
        }
    }

    private func newChat() {
        store.chat.newChat()
        store.route = .newChat
        compactColumn = .detail
    }
    #endif
}

#if os(macOS)
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var serverDraft = ""
    @State private var serverInvalid = false

    private var serverChanged: Bool {
        AppStore.serverURL(serverDraft).map { $0 != store.api.base } ?? true
    }

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $serverDraft, prompt: Text(AppStore.defaultServer))
                    .onSubmit(apply)
                LabeledContent {
                    Button("Apply", action: apply).disabled(!serverChanged)
                } label: {
                    if serverInvalid {
                        Text("Enter an http:// or https:// address.").foregroundStyle(.red)
                    } else {
                        Text("The Django backend, not the web app. Changing it signs you in again.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            } header: {
                Text("Server")
            }
            Section("Account") {
                if store.loggedIn == true {
                    LabeledContent("Signed in as", value: store.account.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                    Button("Sign Out") { Task { await store.logout() } }
                } else {
                    Text("Not signed in").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { serverDraft = store.baseURL }
        .onChange(of: store.baseURL) { _, url in serverDraft = url }
    }

    private func apply() {
        serverInvalid = !store.applyServer(serverDraft)
    }
}
#endif
