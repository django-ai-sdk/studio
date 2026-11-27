import SwiftUI

struct StatusIcon: View {
    let status: String

    var body: some View {
        Group {
            if status == "running" {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: Self.symbol(status)).foregroundStyle(Self.color(status))
            }
        }
        .frame(width: 18, height: 18)
        .help(Self.title(status))
        .accessibilityLabel(Self.title(status))
    }

    static func symbol(_ s: String) -> String {
        switch s {
        case "completed": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "waiting": "hand.raised.circle.fill"
        case "cancelled": "stop.circle.fill"
        case "skipped": "arrow.uturn.forward.circle"
        case "running": "circle.dotted"
        default: "circle.dashed"
        }
    }

    static func color(_ s: String) -> Color {
        switch s {
        case "completed": .green
        case "failed": .red
        case "waiting": .orange
        case "running": .accentColor
        default: .secondary
        }
    }

    static func title(_ s: String) -> String {
        s == "waiting" ? "Waiting for approval" : s.capitalized
    }
}

struct OutputValueView: View {
    let value: JSON

    var body: some View {
        switch value {
        case .string(let s):
            Text(Self.markdown(s)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .null:
            Text("No output").foregroundStyle(.secondary)
        default:
            ScrollView(.horizontal) {
                Text(value.pretty).font(.callout.monospaced()).textSelection(.enabled).padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

struct RunView: View {
    @Environment(WorkflowsModel.self) private var model
    let run: WorkflowRun
    let workflow: WorkflowItem?
    @State private var confirmingCancel = false
    @State private var rejecting: StepRun?

    private var rows: [(name: String, type: String, step: StepRun?)] {
        let runSteps = run.steps ?? []
        var rows = (workflow?.steps ?? []).map { def -> (String, String, StepRun?) in
            let name = def["name"]?.string ?? ""
            return (name, def["type"]?.string ?? "agent", runSteps.last { $0.step_name == name })
        }
        let known = Set(rows.map(\.0))
        rows += runSteps.filter { !known.contains($0.step_name) }.map { ($0.step_name, "", $0) }
        return rows
    }

    private var result: JSON? {
        if let outputs = run.outputs, outputs != .null, outputs.object?.isEmpty != true { return outputs }
        guard run.status == "completed" else { return nil }
        return (run.steps ?? []).sorted { $0.sequence < $1.sequence }.last { ($0.output ?? .null) != .null }?.output
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !run.error.isEmpty {
                    Label(run.error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                ForEach(run.waitingSteps) { approval($0) }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Steps").font(.headline)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        StepRow(name: row.name, type: row.type, step: row.step)
                        Divider()
                    }
                }
                if let result {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Result").font(.headline)
                        if let object = result.object {
                            ForEach(object.keys.sorted(), id: \.self) { key in
                                Text(key).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                OutputValueView(value: object[key] ?? .null)
                            }
                        } else {
                            OutputValueView(value: result)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Reject “\(rejecting?.step_name ?? "")”?",
                            isPresented: Binding { rejecting != nil } set: { if !$0 { rejecting = nil } },
                            presenting: rejecting) { step in
            Button("Reject", role: .destructive) {
                Task { await model.decide(run.id, step: step.step_name, approved: false) }
            }
        } message: { _ in
            Text("The run won’t continue past this step.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusIcon(status: run.status).imageScale(.large)
                Text(StatusIcon.title(run.status)).font(.title2.bold())
                Spacer()
                if run.isCancellable {
                    Button("Cancel Run…", systemImage: "stop.fill", role: .destructive) { confirmingCancel = true }
                        .confirmationDialog("Cancel this run?", isPresented: $confirmingCancel) {
                            Button("Cancel Run", role: .destructive) { Task { await model.cancel(run.id) } }
                            Button("Keep Running", role: .cancel) {}
                        } message: {
                            Text("Steps that haven’t finished are stopped. You can resume the run later.")
                        }
                }
                if run.isResumable {
                    Button("Resume", systemImage: "arrow.clockwise") { Task { await model.resume(run.id) } }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let started = ISODate.parse(run.started_at ?? run.created_at) {
                    GridRow {
                        Text("Started").foregroundStyle(.secondary)
                        Text(started, format: .dateTime.day().month().hour().minute().second())
                    }
                }
                if let start = ISODate.parse(run.started_at), let end = ISODate.parse(run.completed_at) {
                    GridRow {
                        Text("Duration").foregroundStyle(.secondary)
                        Text(Duration.seconds(end.timeIntervalSince(start)),
                             format: .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, fractionalPart: .show(length: 1)))
                    }
                }
                GridRow {
                    Text("Trigger").foregroundStyle(.secondary)
                    Text(run.trigger ?? "manual")
                }
                if run.attempt > 1 {
                    GridRow { Text("Attempt").foregroundStyle(.secondary); Text("\(run.attempt)") }
                }
            }
            .font(.callout)
        }
    }

    private func approval(_ step: StepRun) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("“\(step.step_name)” is waiting for approval", systemImage: "hand.raised.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                if let prompt = step.detail, !prompt.isEmpty {
                    Text(OutputValueView.markdown(prompt)).textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Reject…", role: .destructive) { rejecting = step }
                    Button("Approve") {
                        Task { await model.decide(run.id, step: step.step_name, approved: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(step.id == run.waitingSteps.first?.id ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .help(step.id == run.waitingSteps.first?.id ? "Approve (⌘↩)" : "Approve")
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StepRow: View {
    let name: String
    let type: String
    let step: StepRun?
    @State private var expanded = false

    private var status: String { step?.status ?? "pending" }
    private var hasBody: Bool { (step?.output).map { $0 != .null } == true || step?.error.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasBody {
                Button { withAnimation { expanded.toggle() } } label: {
                    header.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Output shown" : "Output hidden")
                .accessibilityHint(expanded ? "Hides the step's output" : "Shows the step's output")
            } else {
                header
            }
            if expanded, let step {
                if !step.error.isEmpty {
                    Text(step.error).foregroundStyle(.red).textSelection(.enabled)
                }
                if let output = step.output, output != .null { OutputValueView(value: output) }
            }
        }
        .onChange(of: status, initial: true) { _, status in
            if status == "failed" { expanded = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusIcon(status: status)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if hasBody {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private var subtitle: String {
        var parts = [StatusIcon.title(status)]
        if type == "approval" { parts.append("Approval") } else if !type.isEmpty { parts.append(type.capitalized) }
        if let s = ISODate.parse(step?.started_at), let e = ISODate.parse(step?.completed_at) {
            parts.append(String(format: "%.1fs", e.timeIntervalSince(s)))
        }
        return parts.joined(separator: " · ")
    }
}
