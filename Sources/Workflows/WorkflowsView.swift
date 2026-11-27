import SwiftUI

/// Workflows screen (detail column). macOS: workflow list on the left, the selected workflow's
/// inputs and recent runs in the middle, the selected run in an inspector on the right.
/// iOS: a list that pushes the workflow (form and runs); a run opens in a sheet.
struct WorkflowsView: View {
    @Environment(AppStore.self) private var store
    @State private var model = WorkflowsModel()

    var body: some View {
        content
            // Errors inline with a retry rather than a modal alert.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let error = model.error, !model.workflows.isEmpty {
                    RetryBanner(message: error) { Task { await model.refresh() } }
                        .padding([.horizontal, .top])
                }
            }
            .task {
                model.store = store
                await model.load()
            }
            // Outermost, so the inspector/sheet (RunView) and toolbar get the model too.
            .environment(model)
    }

    private var runShown: Binding<Bool> {
        Binding { model.selectedRunID != nil } set: { if !$0 { model.selectedRunID = nil } }
    }

    private var runContent: some View {
        Group {
            if let run = model.run {
                RunView(run: run, workflow: model.selected)
            } else {
                ProgressView("Loading Run…")
            }
        }
        .task(id: "\(model.selectedRunID ?? "")#\(model.pollGeneration)") {
            if let id = model.selectedRunID { await model.follow(id) }
        }
    }

    @ViewBuilder private var emptyOverlay: some View {
        if !model.loaded {
            ProgressView("Loading Workflows…")
        } else if model.workflows.isEmpty, let error = model.error {
            ContentUnavailableView {
                Label("Couldn’t Load Workflows", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.refresh() } }
            }
        } else if model.workflows.isEmpty {
            ContentUnavailableView("No Workflows", systemImage: "flowchart",
                                   description: Text("Create one in the web app."))
        }
    }

    #if os(macOS)
    private var content: some View {
        @Bindable var model = model
        return HSplitView {
            List(selection: $model.selectedID) {
                ForEach(model.workflows) { workflow in
                    WorkflowRow(workflow: workflow).tag(workflow.id)
                }
            }
            .overlay { emptyOverlay }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)

            Group {
                if let workflow = model.selected {
                    WorkflowDetailView(workflow: workflow).id(workflow.id)
                } else if model.loaded && !model.workflows.isEmpty {
                    ContentUnavailableView("Select a Workflow", systemImage: "flowchart")
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(model.selected?.name ?? "Workflows")
        .inspector(isPresented: runShown) {
            runContent.inspectorColumnWidth(min: 300, ideal: 420, max: 700)
        }
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.load(); await model.loadRuns() }
                }
                .keyboardShortcut("r")
            }
        }
    }
    #else
    @Environment(\.horizontalSizeClass) private var sizeClass

    @ViewBuilder private var content: some View {
        if sizeClass == .regular { wide } else { stack }
    }

    /// iPad (regular width): list beside the selected workflow, like the Mac; the run in a sheet.
    private var wide: some View {
        @Bindable var model = model
        return HStack(spacing: 0) {
            List(model.workflows, selection: $model.selectedID) { workflow in
                WorkflowRow(workflow: workflow).tag(workflow.id)
            }
            .overlay { emptyOverlay }
            .refreshable { await model.load(); await model.loadRuns() }
            .frame(width: 280)
            Divider().ignoresSafeArea()
            Group {
                if let workflow = model.selected {
                    WorkflowDetailView(workflow: workflow).id(workflow.id)
                } else if model.loaded && !model.workflows.isEmpty {
                    ContentUnavailableView("Select a Workflow", systemImage: "flowchart")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(model.selected?.name ?? "Workflows")
        .navigationBarTitleDisplayMode(.inline)
        // A sheet rather than an inspector: next to the sidebar, list and form a fourth column
        // leaves the form too narrow, even on a 13-inch iPad.
        .sheet(isPresented: runShown) { runSheet }
    }

    private var runSheet: some View {
        NavigationStack {
            runContent
                .navigationTitle("Run")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.selectedRunID = nil }
                    }
                }
        }
        // Half height on iPhone; iPad shows a centered form sheet.
        .presentationDetents(sizeClass == .compact ? [.medium, .large] : [.large])
        .environment(model)
    }

    /// iPhone: list → workflow (form and runs) → run in a sheet over that workflow.
    private var stack: some View {
        NavigationStack {
            List(model.workflows) { workflow in
                NavigationLink(value: workflow.id) { WorkflowRow(workflow: workflow) }
            }
            .overlay { emptyOverlay }
            .refreshable { await model.load() }
            .navigationTitle("Workflows")
            .navigationDestination(for: String.self) { id in
                Group {
                    if let workflow = model.workflows.first(where: { $0.id == id }) {
                        WorkflowDetailView(workflow: workflow).id(workflow.id)
                    } else {
                        ContentUnavailableView("Workflow Not Found", systemImage: "flowchart")
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                // On the pushed workflow, so the run reads as part of it (not of the list).
                .sheet(isPresented: runShown) { runSheet }
                .environment(model)
            }
        }
    }
    #endif
}

private struct WorkflowRow: View {
    let workflow: WorkflowItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(workflow.name).lineLimit(1)
            Text("\(workflow.steps.count) step\(workflow.steps.count == 1 ? "" : "s") · \(workflow.slug)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .opacity(workflow.active ? 1 : 0.6)
    }
}

/// Middle pane: overview, steps, the input form with Run, and recent runs.
struct WorkflowDetailView: View {
    @Environment(WorkflowsModel.self) private var model
    let workflow: WorkflowItem
    @State private var draft = InputDraft()
    @State private var problems: [String: String] = [:]

    private var fields: [InputField] { InputField.of(workflow) }
    private var approvalWaiting: Bool { model.run?.waitingSteps.isEmpty == false }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workflow.name).font(.title2.bold())
                    Text(summary).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Steps") {
                ForEach(Array(workflow.steps.enumerated()), id: \.offset) { i, step in
                    StepDefinitionRow(index: i + 1, step: step)
                }
            }

            Section {
                if fields.isEmpty {
                    Text("This workflow takes no inputs.").foregroundStyle(.secondary)
                } else {
                    InputFormRows(fields: fields, draft: $draft, problems: problems, onSubmit: run)
                }
            } header: {
                Text("Inputs")
            } footer: {
                HStack {
                    if !workflow.active {
                        Text("This workflow is inactive and cannot run.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button(action: run) {
                        Label("Run Workflow", systemImage: "play.fill").padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    // While an approval waits, ⌘↩ belongs to its Approve button.
                    .keyboardShortcut(approvalWaiting ? nil : KeyboardShortcut(.return, modifiers: .command))
                    .help(approvalWaiting ? "Run" : "Run (⌘↩)")
                    .disabled(model.busy || !workflow.active)
                }
                .padding(.top, 4)
            }

            Section("Recent Runs") {
                if model.runs.isEmpty {
                    Text("No runs yet.").foregroundStyle(.secondary)
                }
                ForEach(model.runs) { run in
                    RunRow(run: run, selected: run.id == model.selectedRunID) { model.selectedRunID = run.id }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = InputDraft(fields) }
        .task {
            // On iOS the workflow is pushed rather than selected in a list.
            if model.selectedID != workflow.id { model.selectedID = workflow.id }
            await model.loadRuns()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Run", systemImage: "play.fill", action: run)
                    .disabled(model.busy || !workflow.active)
                    .help("Run this workflow with the inputs below")
            }
        }
    }

    private var summary: String {
        let n = workflow.steps.count
        var parts = ["\(n) step\(n == 1 ? "" : "s")", "Key: \(workflow.slug)"]
        let triggers = workflow.definition["triggers"]?.array?.count ?? 0
        if triggers > 0 { parts.append("\(triggers) trigger\(triggers == 1 ? "" : "s")") }
        if !workflow.active { parts.append("Inactive") }
        return parts.joined(separator: " · ")
    }

    private func run() {
        switch draft.inputs(fields) {
        case .failure(let p): problems = p.byField
        case .success(let inputs):
            problems = [:]
            // `JSON(any:)` also passes `[String: JSON]` through unchanged.
            let inputs = inputs.mapValues { JSON(any: $0) }
            Task { await model.start(workflow, inputs: inputs) }
        }
    }
}

private struct StepDefinitionRow: View {
    let index: Int
    let step: JSON

    private var type: String { step["type"]?.string ?? "agent" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: type == "approval" ? "hand.raised" : type == "agent" ? "sparkles" : "gearshape")
                .foregroundStyle(type == "approval" ? .orange : .accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(index). \(step["name"]?.string ?? "Step")").fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var detail: String {
        var parts: [String] = [type == "approval" ? "Approval" : type.capitalized]
        if type == "approval", let prompt = step["config"]?["prompt"]?.string, !prompt.isEmpty { parts.append(prompt) }
        if let requires = step["requires"]?.array?.compactMap(\.string), !requires.isEmpty {
            parts.append("after " + requires.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

private struct RunRow: View {
    let run: WorkflowRun
    let selected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                StatusIcon(status: run.status)
                VStack(alignment: .leading, spacing: 1) {
                    if let date = ISODate.parse(run.created_at) {
                        Text(date, format: .relative(presentation: .named)).fontWeight(selected ? .semibold : .regular)
                    }
                    Text([StatusIcon.title(run.status), run.trigger ?? "manual"].joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.15) : nil)
    }
}
