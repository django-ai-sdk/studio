import Foundation

nonisolated enum Part {
    static func type(_ part: JSON) -> String { part["type"]?.string ?? "" }

    static func isTool(_ part: JSON) -> Bool {
        let t = type(part)
        return t.hasPrefix("tool-") || t == "dynamic-tool"
    }

    static func toolName(_ part: JSON) -> String {
        if let name = part["toolName"]?.string { return name }
        let t = type(part)
        return t.hasPrefix("tool-") ? String(t.dropFirst(5)) : (part["title"]?.string ?? "tool")
    }

    static func isArtifact(_ part: JSON) -> Bool { isTool(part) && toolName(part).hasPrefix("artifact_") }

    static let citationsTool = "artifact_citations_artifact"
    static func isCitations(_ part: JSON) -> Bool { isTool(part) && toolName(part) == citationsTool }

    static func humanize(_ name: String) -> String {
        var s = name
        if s.hasPrefix("artifact_") { s.removeFirst(9) }
        if s.hasSuffix("_artifact") { s.removeLast(9) }
        return s.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func isRunning(_ part: JSON) -> Bool {
        if type(part) == "reasoning" { return part["state"]?.string == "streaming" }
        return !["output-available", "output-error", "output-denied", "denied"].contains(part["state"]?.string ?? "")
    }

    static func toolError(_ part: JSON) -> String? {
        if part["state"]?.string == "output-error" {
            return friendlyError(part["errorText"]?.string ?? "tool_failed")
        }
        let out = part["output"]
        if let m = out?["error_message"]?.string, !m.isEmpty { return m }
        if let m = out?["error"]?.string, !m.isEmpty { return m }
        if out?["error"]?.bool == true { return out?["result"]?.string ?? "Tool error" }
        return nil
    }

    static func friendlyError(_ code: String) -> String {
        switch code {
        case "tool_failed": "The tool failed."
        default: code.contains(" ") ? code : code.replacingOccurrences(of: "_", with: " ").capitalizedFirst
        }
    }

    static func toolResult(_ part: JSON) -> JSON? {
        guard let output = part["output"], output != .null else { return nil }
        if let result = output["result"], output.object?.count == 1 || output["origin"] != nil {
            if let s = result.string, let parsed = try? JSONDecoder().decode(JSON.self, from: Data(s.utf8)),
               parsed.object != nil || parsed.array != nil {
                return parsed
            }
            return result
        }
        return output
    }

    static func artifactArgs(_ part: JSON) -> JSON {
        if let input = part["input"], input.object?.isEmpty == false { return input }
        let out = part["output"]
        if let wrapped = out?["result"], wrapped.object?.isEmpty == false { return wrapped }
        return out ?? .object([:])
    }

    static func artifactOutput(_ part: JSON) -> JSON? {
        let out = part["output"]
        if let wrapped = out?["result"], wrapped.object?.isEmpty == false { return wrapped }
        return out
    }

    static func agentMarks(_ part: JSON) -> (agent: String?, handoff: String?) {
        let sdk = part["callProviderMetadata"]?["sdk"]
        return (sdk?["agent"]?.string, sdk?["handoff"]?.string)
    }

    static func dedupTools(_ parts: [JSON]) -> [JSON] {
        let rank = ["output-available": 4, "output-error": 3, "approval-requested": 2, "input-available": 1, "input-streaming": 0]
        var best: [String: (JSON, Int)] = [:]
        for p in parts where isTool(p) {
            guard let id = p["toolCallId"]?.string else { continue }
            let r = rank[p["state"]?.string ?? ""] ?? -1
            if r > best[id]?.1 ?? Int.min { best[id] = (p, r) }
        }
        var seen = Set<String>()
        return parts.compactMap { p in
            guard isTool(p), let id = p["toolCallId"]?.string else { return p }
            guard seen.insert(id).inserted else { return nil }
            return best[id]?.0
        }
    }
}

nonisolated extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

nonisolated extension JSON {
    var inlineText: String {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): b ? "true" : "false"
        case .null: ""
        default: pretty
        }
    }
}

nonisolated enum Oversight {
    static func notices(_ parts: [JSON]) -> [JSON] {
        parts.filter { Part.type($0) == "data-oversight" }.compactMap { $0["data"] }
    }

    static func replacementText(_ parts: [JSON]) -> String? {
        let ns = notices(parts).reversed()
        if let r = ns.first(where: { $0["replace"]?.string != nil })?["replace"]?.string { return r }
        return ns.first(where: { $0["outcome"]?.string == "blocked" && $0["message"]?.string != nil })?["message"]?.string
    }

    struct Line: Hashable { let kind: String; let text: String }

    static func lines(_ parts: [JSON]) -> [Line] {
        notices(parts).flatMap { n -> [Line] in
            if let notes = n["notes"]?.array, !notes.isEmpty {
                return notes.map { Line(kind: $0["kind"]?.string ?? "", text: $0["text"]?.string ?? "") }
            }
            let gate = n["stage"]?.string == "gate"
            switch n["outcome"]?.string {
            case "blocked":
                return [Line(kind: "block", text: gate ? "This question was not sent to the assistant." : "The answer was withheld.")]
            case "masked":
                return [Line(kind: "mask", text: gate ? "Part of your question was hidden from the assistant." : "Part of the answer was hidden.")]
            default: return []
            }
        }
    }
}

nonisolated struct Citations {
    struct Source: Identifiable, Hashable {
        let key: String
        let number: Int
        let title: String
        let kind: String
        let content: String
        let url: URL?
        let cited: Bool
        var id: String { key }
    }
    struct Evidence: Hashable { let key: String; let text: String }
    struct Citation: Identifiable, Hashable {
        let index: Int
        let start: Int
        let end: Int
        let quote: String
        let evidence: [Evidence]
        var id: Int { index }
    }

    let citations: [Citation]
    let sources: [Source]

    init?(parts: [JSON]) {
        guard let part = parts.first(where: { Part.isCitations($0) && $0["state"]?.string == "output-available" }),
              var data = part["output"] else { return nil }
        if let s = data.string, let d = try? JSONDecoder().decode(JSON.self, from: Data(s.utf8)) { data = d }
        if let r = data["result"] { data = r }
        if let s = data.string, let d = try? JSONDecoder().decode(JSON.self, from: Data(s.utf8)) { data = d }
        guard let cs = data["citations"]?.array, let ss = data["sources"]?.array else { return nil }
        sources = ss.map {
            Source(key: $0["key"]?.string ?? "", number: Int($0["number"]?.number ?? 0),
                   title: $0["title"]?.string ?? "Untitled", kind: $0["kind"]?.string ?? "document",
                   content: $0["content"]?.string ?? "", url: $0["url"]?.string.flatMap(URL.init(string:)),
                   cited: $0["cited"]?.bool ?? false)
        }
        citations = cs.enumerated().map { i, c in
            Citation(index: i, start: Int(c["start"]?.number ?? 0), end: Int(c["end"]?.number ?? 0),
                     quote: c["quote"]?.string ?? "",
                     evidence: (c["evidence"]?.array ?? []).map {
                         Evidence(key: $0["key"]?.string ?? "", text: $0["text"]?.string ?? "")
                     })
        }
    }

    var citedSources: [Source] { sources.filter(\.cited).sorted { $0.number < $1.number } }

    func source(_ key: String) -> Source? { sources.first { $0.key == key } }

    func annotate(_ text: String) -> String {
        var inserts: [(String.Index, String)] = []
        for c in citations {
            let numbers = c.evidence.compactMap { source($0.key)?.number }.filter { $0 > 0 }
            let label = Array(Set(numbers)).sorted().map(String.init).joined(separator: ",")
            guard !label.isEmpty, let at = end(of: c, in: text) else { continue }
            inserts.append((at, "[\(Self.superscript(label))](studio-cite://\(c.index))"))
        }
        var out = text
        for (at, marker) in inserts.sorted(by: { $0.0 > $1.0 }) { out.insert(contentsOf: marker, at: at) }
        return out
    }

    private func end(of c: Citation, in text: String) -> String.Index? {
        let scalars = text.unicodeScalars
        if c.start >= 0, c.end <= scalars.count, c.start < c.end {
            let s = scalars.index(scalars.startIndex, offsetBy: c.start)
            let e = scalars.index(scalars.startIndex, offsetBy: c.end)
            if String(scalars[s..<e]) == c.quote, let idx = e.samePosition(in: text) { return idx }
        }
        guard !c.quote.isEmpty else { return nil }
        return text.range(of: c.quote)?.upperBound
    }

    static func superscript(_ s: String) -> String {
        let map: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵",
                                           "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", ",": "˒"]
        return String(s.map { map[$0] ?? $0 })
    }
}
