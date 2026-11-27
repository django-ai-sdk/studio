import SwiftUI

/// State shared by the agents screens: which agents are runtime (editable) agents and the
/// option lists the builder offers. The agent list itself lives in `AppStore.agents`.
@Observable @MainActor
final class AgentsModel {
    var runtime: [String: RuntimeAgent] = [:]
    var bases: [RuntimeAgentBase] = []
    var toolOptions: [RuntimeAgentToolOption] = []
    var integrations: [IntegrationOption] = []
    var memories: [MemoryOption] = []
    /// Per-agent details (description etc.) for the gallery, fetched lazily as cards appear.
    var details: [String: AgentInfo] = [:]
    var loaded = false
    var error: String?
    @ObservationIgnored private var fetching: Set<String> = []

    func reload(_ api: API) async {
        do {
            runtime = Dictionary(try await api.runtimeAgents().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    func loadDetails(_ id: String, api: API) async {
        guard details[id] == nil, !fetching.contains(id) else { return }
        fetching.insert(id)
        defer { fetching.remove(id) }
        if let info = try? await api.agentInfo(id) { details[id] = info }
    }

    /// Builder options; the optional endpoints (integrations, memories) may be absent.
    func loadOptions(_ api: API) async {
        async let b = try? api.runtimeAgentBases()
        async let t = try? api.runtimeAgentTools()
        async let i = try? api.integrations()
        async let m = try? api.memories()
        let (bases, tools, integrations, memories) = await (b, t, i, m)
        self.bases = bases ?? []
        self.toolOptions = tools ?? []
        self.integrations = integrations ?? []
        self.memories = memories ?? []
    }
}

/// What an agent can do, as quiet SF Symbols (cards, rows) or small labelled symbols (headers).
struct CapabilityBadges: View {
    enum Style { case symbols, labels }

    var fileUpload: Bool
    var rag: Bool
    var vision: Bool
    var custom = false
    var inactive = false
    var style: Style = .labels

    private var items: [(title: String, symbol: String)] {
        var items: [(String, String)] = []
        if custom { items.append(("Custom", "hammer")) }
        if fileUpload { items.append(("Files", "paperclip")) }
        if rag { items.append(("Knowledge", "books.vertical")) }
        if vision { items.append(("Vision", "eye")) }
        return items
    }

    var body: some View {
        if !items.isEmpty || inactive {
            HStack(spacing: style == .symbols ? 8 : 12) {
                ForEach(items, id: \.title) { item in
                    switch style {
                    case .symbols:
                        Image(systemName: item.symbol)
                            .help(item.title)
                            .accessibilityLabel(item.title)
                    case .labels:
                        Label(item.title, systemImage: item.symbol)
                            .labelStyle(CompactLabelStyle())
                    }
                }
                if inactive {
                    Label("Inactive", systemImage: "pause.circle.fill")
                        .labelStyle(CompactLabelStyle())
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .imageScale(style == .symbols ? .medium : .small)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private struct CompactLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 3) { configuration.icon; configuration.title }
        }
    }
}

/// Icon tile with the agent's initial (or a symbol): a soft accent-tinted fill with an
/// accent-coloured glyph, the same calm treatment for every agent (like Settings rows).
struct AgentIcon: View {
    let id: String
    let name: String
    var size: CGFloat = 40
    var symbol: String? = nil

    private var monogram: String {
        name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        shape
            .fill(.tint.opacity(0.14))
            .overlay(shape.strokeBorder(.tint.opacity(0.18), lineWidth: 0.5))
            .overlay {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: size * 0.44, weight: .semibold))
                } else {
                    Text(monogram).font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                }
            }
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
