import SwiftUI

enum OversightFormat {
    static func humanize(_ name: String) -> String { name.replacingOccurrences(of: "_", with: " ") }

    static func label(_ name: String) -> String {
        let text = humanize(name)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) \(n == 1 ? one : many ?? one + "s")"
    }

    static func list(_ values: [String], last: String = "and") -> String {
        guard values.count > 1 else { return values.joined() }
        return values.dropLast().joined(separator: ", ") + " \(last) " + values.last!
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    static func seconds(_ ms: Double) -> String {
        ms < 1000 ? "\(Int(ms.rounded())) ms" : String(format: "%.1f s", ms / 1000)
    }

    static func time(_ iso: String) -> String {
        ISODate.parse(iso)?.formatted(date: .omitted, time: .shortened) ?? ""
    }

    static func when(_ iso: String) -> String {
        ISODate.parse(iso)?.formatted(.dateTime.month(.abbreviated).day().hour().minute()) ?? ""
    }

    static func value(_ value: JSON?) -> String {
        switch value {
        case nil, .null?: "—"
        case .bool(let b)?: b ? "yes" : "no"
        case .number(let n)?: String(format: "%.2f", n)
        case .string(let s)?: humanize(s)
        case .array(let a)?: a.isEmpty ? "none" : a.map { $0.string.map(humanize) ?? self.value($0) }.joined(separator: ", ")
        case .object?: value?.pretty ?? ""
        }
    }
}

struct OversightStageInfo {
    let key: String
    let name: String
    let title: String
    let when: String
    let symbol: String

    static let all: [OversightStageInfo] = [
        .init(key: "gate", name: "Gate", title: "Before the model",
              when: "Checks the question before it is stored or reaches the model. Can block it, hide parts of it, or take tools away.",
              symbol: "shield"),
        .init(key: "tool", name: "Tool", title: "Tool calls",
              when: "Checks each tool call before it runs, and each result. Can refuse the call.",
              symbol: "wrench.and.screwdriver"),
        .init(key: "finish", name: "Finish", title: "Before the user sees it",
              when: "Checks the answer once it is complete, before it is stored. Can hide parts of it or withhold it.",
              symbol: "text.bubble"),
        .init(key: "reflect", name: "Reflect", title: "Afterwards",
              when: "Runs in the background after the turn is recorded. Only records and alerts; it cannot change the turn.",
              symbol: "clock.arrow.circlepath"),
    ]

    static func of(_ key: String) -> OversightStageInfo {
        all.first { $0.key == key }
            ?? .init(key: key, name: OversightFormat.label(key), title: OversightFormat.label(key), when: "", symbol: "circle")
    }
}

struct OversightStage: Identifiable {
    enum Status { case completed, failed, running, pending }

    let info: OversightStageInfo
    let status: Status
    let answers: [OversightAnswer]
    let matches: [OversightMatch]
    let reviews: [OversightReview]
    var id: String { info.key }

    var summary: String {
        var parts: [String] = []
        if !answers.isEmpty { parts.append(OversightFormat.plural(answers.count, "check")) }
        if !reviews.isEmpty { parts.append("sent to review") }
        else if let acted = Self.actedLabel(matches) { parts.append(acted) }
        else if !matches.isEmpty { parts.append(OversightFormat.plural(matches.count, "rule reported", "rules reported")) }
        else if status == .completed || status == .failed { parts.append("no rule matched") }
        if parts.isEmpty {
            if status == .running { return "Checking…" }
            if info.key == "reflect" { return "Runs in the background" }
            return status == .pending ? "Not reached" : "Nothing ran"
        }
        return parts.joined(separator: " · ")
    }

    static func actedLabel(_ matches: [OversightMatch]) -> String? {
        var names: [String] = []
        for m in matches where m.acted {
            let n = OversightFormat.humanize(m.rule)
            if !names.contains(n) { names.append(n) }
        }
        guard !names.isEmpty else { return nil }
        let text = names.count > 2 ? "\(names.count) rules acted" : "\(names.joined(separator: " and ")) acted"
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func stages(of turn: OversightTurn) -> [OversightStage] {
        var reachedOpen = false
        let known = Set(OversightStageInfo.all.map(\.key))
        let extra = Set((turn.answers ?? []).map(\.stage) + (turn.matches ?? []).map(\.stage)).subtracting(known).sorted()
        return (OversightStageInfo.all + extra.map(OversightStageInfo.of)).map { info in
            let answers = (turn.answers ?? []).filter { $0.stage == info.key }
            let matches = (turn.matches ?? []).filter { $0.stage == info.key }
            let rules = Set(matches.map(\.rule))
            let reviews = (turn.reviews ?? []).filter { $0.rule.map(rules.contains) ?? false }
            let failed = matches.contains(where: \.acted) || !reviews.isEmpty
            let ran = !answers.isEmpty || !matches.isEmpty
            let status: Status
            if failed { status = .failed }
            else if info.key == "reflect" {
                status = turn.closed && turn.reflecting ? .running : (turn.reflected == true || ran) ? .completed : .pending
            } else if turn.closed || ran { status = .completed }
            else if !reachedOpen { reachedOpen = true; status = .running }
            else { status = .pending }
            return OversightStage(info: info, status: status, answers: answers, matches: matches, reviews: reviews)
        }
    }
}

struct OversightTone {
    let label: String
    let symbol: String
    let color: Color

    static func outcome(_ outcome: String) -> OversightTone {
        switch outcome {
        case "blocked": .init(label: "Blocked", symbol: "nosign", color: .red)
        case "restricted": .init(label: "Tools restricted", symbol: "wrench.and.screwdriver", color: .orange)
        case "masked": .init(label: "Masked", symbol: "eye.slash", color: .orange)
        case "flagged": .init(label: "Flagged", symbol: "flag", color: .blue)
        case "allowed": .init(label: "Allowed", symbol: "checkmark", color: .green)
        default: .init(label: outcome.isEmpty ? "Unfinished" : OversightFormat.label(outcome), symbol: "hourglass", color: .secondary)
        }
    }

    static func turn(_ turn: OversightTurn) -> OversightTone {
        if !turn.closed { return .init(label: "Checking", symbol: "hourglass", color: .blue) }
        if (turn.reviews_open ?? 0) > 0 { return .init(label: "In review", symbol: "person.badge.clock", color: .purple) }
        return outcome(turn.outcome)
    }

    static func answer(_ a: OversightAnswer) -> OversightTone {
        let text = OversightFormat.value(a.value)
        if let error = a.error, !error.isEmpty { return .init(label: "Error", symbol: "exclamationmark.circle", color: .red) }
        switch a.value {
        case .number(let n)?:
            return .init(label: text, symbol: "gauge.with.dots.needle.50percent", color: n < 0.5 ? .orange : .green)
        case .string(let s)?:
            let tones: [String: Color] = ["confused": .blue, "worried": .blue, "frustrated": .orange, "angry": .red]
            if let c = tones[s] { return .init(label: text, symbol: "exclamationmark.bubble", color: c) }
            return .init(label: text, symbol: "face.smiling", color: .green)
        case .bool(true)?:
            return .init(label: text, symbol: "smallcircle.filled.circle", color: .orange)
        case .array(let items)? where !items.isEmpty:
            return .init(label: text, symbol: "smallcircle.filled.circle", color: .orange)
        default:
            return .init(label: text, symbol: "checkmark.circle", color: .green)
        }
    }

    static func match(_ m: OversightMatch, reviewed: Bool) -> OversightTone {
        let kinds = m.actionKinds
        let symbol: String, color: Color
        if kinds.contains("block") { (symbol, color) = ("nosign", .red) }
        else if kinds.contains("restrict_tools") { (symbol, color) = ("wrench.and.screwdriver", .red) }
        else if kinds.contains("mask") { (symbol, color) = ("eye.slash", .orange) }
        else if kinds.contains("queue") { (symbol, color) = ("person.badge.clock", .purple) }
        else if kinds.contains("notify") { (symbol, color) = ("bell.badge", .blue) }
        else if kinds.contains("alert") { (symbol, color) = ("flag", .blue) }
        else { (symbol, color) = ("checkmark.shield", .secondary) }
        let label = reviewed ? "In review" : m.acted ? "Acted" : "Reported"
        return .init(label: label, symbol: symbol, color: m.acted || reviewed ? color : .secondary)
    }

    static func mode(_ mode: String) -> OversightTone {
        switch mode {
        case "enforce": .init(label: "Enforced", symbol: "circle.fill", color: .green)
        case "report": .init(label: "Report only", symbol: "circle.fill", color: .orange)
        default: .init(label: "Off", symbol: "circle.fill", color: .secondary)
        }
    }
}

indirect enum OversightCondition: Hashable {
    case text(String)
    case group(all: Bool, items: [OversightCondition])
    case not(OversightCondition)

    static func describe(_ value: JSON?) -> OversightCondition {
        guard let value else { return .text("Every turn") }
        if value == .bool(true) { return .text("Every turn") }
        guard case .object(let node) = value else { return .text(OversightFormat.value(value)) }
        if node["always"]?.bool == true { return .text("Every turn") }
        if let children = node["all"]?.array ?? node["any"]?.array {
            let all = node["all"] != nil
            var items: [OversightCondition] = []
            var previous: [String: JSON]?
            for child in children {
                let c = child.object ?? [:]
                let op = c["op"]?.string ?? ""
                if all, case .text(let last)? = items.last, let p = previous, op == "confident" || op == "unsure",
                   p["lens"] == c["lens"], p["op"]?.string != "confident", p["op"]?.string != "unsure" {
                    let v = c["value"]?.number ?? 0
                    let tail = op == "confident" ? "with confidence at least \(OversightFormat.percent(v))"
                                                 : "with confidence below \(OversightFormat.percent(v))"
                    items[items.count - 1] = .text("\(last), \(tail)")
                    previous = nil
                    continue
                }
                items.append(describe(child))
                previous = c["lens"] != nil ? c : nil
            }
            return items.count == 1 ? items[0] : .group(all: all, items: items)
        }
        if let inner = node["not"] { return .not(describe(inner)) }
        if let lens = node["lens"]?.string, let op = node["op"]?.string {
            return .text(compare(lens: OversightFormat.label(lens), op: op, value: node["value"]))
        }
        return .text(value.pretty)
    }

    private static func compare(lens who: String, op: String, value: JSON?) -> String {
        let v = OversightFormat.value(value)
        let pct = value?.number.map(OversightFormat.percent) ?? v
        switch op {
        case "is_true": return "\(who) is yes"
        case "is_false": return "\(who) is no"
        case "eq": return "\(who) is \(v)"
        case "ne": return "\(who) is not \(v)"
        case "gt": return "\(who) is above \(v)"
        case "ge": return "\(who) is at least \(v)"
        case "lt": return "\(who) is below \(v)"
        case "le": return "\(who) is at most \(v)"
        case "in": return "\(who) is \(OversightFormat.list((value?.array ?? []).map { OversightFormat.value($0) }, last: "or"))"
        case "contains": return "\(who) includes \(v)"
        case "any": return "\(who) found something"
        case "missing": return "\(who) has no answer"
        case "present": return "\(who) has an answer"
        case "confident": return "\(who) is at least \(pct) sure"
        case "unsure": return "\(who) is less than \(pct) sure"
        default: return "\(who) \(OversightFormat.humanize(op)) \(value == nil ? "" : v)".trimmingCharacters(in: .whitespaces)
        }
    }
}

enum OversightAction {
    static func describe(_ action: JSON, stage: String) -> String {
        let kind = action["kind"]?.string ?? ""
        let severity = action["severity"]?.string.map { " (\(OversightFormat.humanize($0)))" } ?? ""
        switch kind {
        case "block":
            let what = switch stage {
            case "gate": "Refuses the question"
            case "tool": "Refuses the tool call"
            case "finish": "Withholds the answer"
            default: "Records a block"
            }
            if let message = action["message"]?.string, !message.isEmpty { return "\(what) and replies “\(message)”" }
            return what
        case "mask":
            let lenses = (action["lenses"]?.array ?? []).compactMap(\.string).map(OversightFormat.label)
            let what = lenses.isEmpty ? "what its lenses found" : "what \(OversightFormat.list(lenses)) found"
            let where_ = switch stage {
            case "gate": ", before the model or the thread sees it"
            case "finish": " in the stored answer"
            case "reflect": " in the stored message, afterwards"
            default: ""
            }
            let template = action["template"]?.string.map { " as \($0)" } ?? ""
            return "Hides \(what)\(where_)\(template)"
        case "restrict_tools":
            let names = (action["names"]?.array ?? []).compactMap(\.string)
            return names.isEmpty ? "Takes away all tools for this turn" : "Takes away the tools \(OversightFormat.list(names)) for this turn"
        case "queue":
            let queue = action["queue"]?.string.map(OversightFormat.humanize) ?? "default"
            let priority = action["priority"].map { ", priority \(OversightFormat.value($0))" } ?? ""
            return "Queues the turn for review in \(queue)\(priority)"
        case "notify":
            let to = (action["to"]?.array ?? []).compactMap(\.string).map(OversightFormat.label)
            return to.isEmpty ? "Notifies everyone set up to hear about it\(severity)" : "Notifies \(OversightFormat.list(to))\(severity)"
        case "alert":
            return "Raises an alert\(severity)"
        default:
            return OversightFormat.label(kind.isEmpty ? "act" : kind)
        }
    }
}
