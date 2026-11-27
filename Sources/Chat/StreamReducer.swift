import Foundation

enum StreamReducer {
    static func apply(_ event: JSON, to message: inout ChatMessage) throws {
        guard let type = event["type"]?.string else { return }
        let scratch = StreamScratch.shared
        let key = message.id

        switch type {
        case "start":
            if let id = event["messageId"]?.string { setMeta(&message, "id", .string(id)) }

        case "text-start", "reasoning-start":
            let kind = type == "text-start" ? "text" : "reasoning"
            var part: [String: JSON] = ["type": .string(kind), "text": .string(""), "state": .string("streaming")]
            if let meta = event["providerMetadata"], meta != .null { part["providerMetadata"] = meta }
            message.parts.append(.object(part))
            scratch.open(key, block: event["id"]?.string ?? "", at: message.parts.count - 1)
            if kind == "reasoning" { scratch.startThinking(key, part: message.parts.count - 1) }

        case "text-delta", "reasoning-delta":
            let kind = type == "text-delta" ? "text" : "reasoning"
            let delta = event["delta"]?.string ?? ""
            let i = scratch.index(key, block: event["id"]?.string ?? "")
                ?? openFallback(kind, in: &message, scratch: scratch, block: event["id"]?.string ?? "")
            guard message.parts.indices.contains(i) else { return }
            message.parts[i]["text"] = .string((message.parts[i]["text"]?.string ?? "") + delta)

        case "text-end", "reasoning-end":
            guard let i = scratch.close(key, block: event["id"]?.string ?? ""),
                  message.parts.indices.contains(i) else { return }
            message.parts[i]["state"] = .string("done")
            if type == "reasoning-end" { scratch.stopThinking(key, part: i) }

        case "tool-input-start":
            guard let id = event["toolCallId"]?.string else { return }
            scratch.resetInput(id)
            updateTool(&message, id: id, name: event["toolName"]?.string, state: "input-streaming",
                       fields: ["input": nil], callMetadata: event["providerMetadata"])

        case "tool-input-delta":
            guard let id = event["toolCallId"]?.string else { return }
            let text = scratch.appendInput(id, event["inputTextDelta"]?.string ?? "")
            updateTool(&message, id: id, name: nil, state: "input-streaming",
                       fields: ["input": PartialJSON.parse(text)], callMetadata: nil)

        case "tool-input-available":
            guard let id = event["toolCallId"]?.string else { return }
            updateTool(&message, id: id, name: event["toolName"]?.string, state: "input-available",
                       fields: ["input": event["input"]], callMetadata: event["providerMetadata"])

        case "tool-input-error":
            guard let id = event["toolCallId"]?.string else { return }
            updateTool(&message, id: id, name: event["toolName"]?.string, state: "output-error",
                       fields: ["input": event["input"], "errorText": event["errorText"]], callMetadata: nil)

        case "tool-output-available":
            guard let id = event["toolCallId"]?.string else { return }
            updateTool(&message, id: id, name: nil, state: "output-available",
                       fields: ["output": event["output"]], callMetadata: nil)

        case "tool-output-error":
            guard let id = event["toolCallId"]?.string else { return }
            updateTool(&message, id: id, name: nil, state: "output-error",
                       fields: ["errorText": event["errorText"]], callMetadata: nil)

        case "tool-output-denied":
            guard let id = event["toolCallId"]?.string else { return }
            updateTool(&message, id: id, name: nil, state: "output-denied", fields: [:], callMetadata: nil)

        case "source-url":
            message.parts.append(pick(event, as: "source-url", ["sourceId", "url", "title", "providerMetadata"]))

        case "source-document":
            message.parts.append(pick(event, as: "source-document",
                                      ["sourceId", "mediaType", "title", "filename", "providerMetadata"]))

        case "file":
            message.parts.append(pick(event, as: "file", ["mediaType", "url", "filename", "providerMetadata"]))

        case "start-step":
            message.parts.append(.object(["type": .string("step-start")]))

        case "finish-step":
            scratch.closeAll(key)

        case "finish":
            closeStreaming(&message)
            setMeta(&message, "finish_reason", event["finishReason"] ?? .string("stop"))
            scratch.end(key)

        case "abort":
            closeStreaming(&message)
            for i in message.parts.indices where Part.isTool(message.parts[i]) && Part.isRunning(message.parts[i]) {
                message.parts[i]["state"] = .string("output-error")
                if message.parts[i]["errorText"] == nil { message.parts[i]["errorText"] = .string("Stopped") }
            }
            setMeta(&message, "finish_reason", .string("abort"))
            scratch.end(key)

        case "error":
            if !message.parts.contains(where: { $0["type"]?.string == "data-error" }) {
                let text = event["errorText"]?.string ?? "Something went wrong."
                message.parts.append(.object(["type": .string("data-error"),
                                              "data": .object(["message": .string(text)])]))
            }

        case "message-metadata":
            break

        default:
            guard type.hasPrefix("data-"), event["transient"]?.bool != true else { return }
            var part: [String: JSON] = ["type": .string(type), "data": event["data"] ?? .null]
            if let id = event["id"]?.string {
                part["id"] = .string(id)
                if let i = message.parts.firstIndex(where: { $0["type"]?.string == type && $0["id"]?.string == id }) {
                    message.parts[i]["data"] = event["data"] ?? .null
                    return
                }
            }
            message.parts.append(.object(part))
        }
    }

    private static func setMeta(_ message: inout ChatMessage, _ key: String, _ value: JSON) {
        if message.meta?.object == nil { message.meta = .object([:]) }
        message.meta?[key] = value
    }

    private static func openFallback(_ kind: String, in message: inout ChatMessage, scratch: StreamScratch, block: String) -> Int {
        if let i = message.parts.indices.last, message.parts[i]["type"]?.string == kind,
           message.parts[i]["state"]?.string != "done" {
            return i
        }
        message.parts.append(.object(["type": .string(kind), "text": .string(""), "state": .string("streaming")]))
        scratch.open(message.id, block: block, at: message.parts.count - 1)
        return message.parts.count - 1
    }

    private static func updateTool(_ message: inout ChatMessage, id: String, name: String?, state: String,
                                   fields: [String: JSON?], callMetadata: JSON?) {
        if let i = message.parts.firstIndex(where: { $0["toolCallId"]?.string == id && Part.isTool($0) }) {
            message.parts[i]["state"] = .string(state)
            for (k, v) in fields { message.parts[i][k] = v }
            if let callMetadata, callMetadata != .null { message.parts[i]["callProviderMetadata"] = callMetadata }
        } else {
            var part: [String: JSON] = [
                "type": .string("tool-\(name ?? "unknown")"),
                "toolCallId": .string(id),
                "state": .string(state),
            ]
            for (k, v) in fields { if let v { part[k] = v } }
            if let callMetadata, callMetadata != .null { part["callProviderMetadata"] = callMetadata }
            message.parts.append(.object(part))
        }
    }

    private static func pick(_ event: JSON, as type: String, _ keys: [String]) -> JSON {
        var part: [String: JSON] = ["type": .string(type)]
        for k in keys { if let v = event[k], v != .null { part[k] = v } }
        return .object(part)
    }

    private static func closeStreaming(_ message: inout ChatMessage) {
        for i in message.parts.indices where message.parts[i]["state"]?.string == "streaming" {
            message.parts[i]["state"] = .string("done")
            if message.parts[i]["type"]?.string == "reasoning" { StreamScratch.shared.stopThinking(message.id, part: i) }
        }
    }
}

final class StreamScratch: @unchecked Sendable {
    static let shared = StreamScratch()
    private let lock = NSLock()
    private var blocks: [String: [String: Int]] = [:]
    private var inputs: [String: String] = [:]
    private var thinkingStart: [String: Date] = [:]
    private var thinkingTime: [String: TimeInterval] = [:]

    private func locked<T>(_ work: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return work() }

    func open(_ message: String, block: String, at index: Int) { locked { blocks[message, default: [:]][block] = index } }
    func index(_ message: String, block: String) -> Int? { locked { blocks[message]?[block] } }
    func close(_ message: String, block: String) -> Int? { locked { blocks[message]?.removeValue(forKey: block) } }
    func closeAll(_ message: String) { locked { blocks[message] = nil } }
    func end(_ message: String) { locked { blocks[message] = nil } }

    func resetInput(_ call: String) { locked { inputs[call] = "" } }
    func appendInput(_ call: String, _ delta: String) -> String {
        locked { inputs[call, default: ""] += delta; return inputs[call]! }
    }

    func startThinking(_ message: String, part: Int) { locked { thinkingStart["\(message)#\(part)"] = Date() } }
    func stopThinking(_ message: String, part: Int) {
        locked {
            let key = "\(message)#\(part)"
            if let start = thinkingStart.removeValue(forKey: key) { thinkingTime[key] = Date().timeIntervalSince(start) }
        }
    }

    func thinkingDuration(_ message: String, part: Int) -> TimeInterval? { locked { thinkingTime["\(message)#\(part)"] } }
    func thinkingDuration(_ message: String) -> TimeInterval? {
        locked {
            let times = thinkingTime.filter { $0.key.hasPrefix("\(message)#") }.map(\.value)
            return times.isEmpty ? nil : times.reduce(0, +)
        }
    }
}

enum PartialJSON {
    static func parse(_ text: String) -> JSON? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let full = decode(trimmed) { return full }
        var stack: [Character] = []
        var inString = false, escaped = false
        for c in trimmed {
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{": stack.append("}")
            case "[": stack.append("]")
            case "}", "]": _ = stack.popLast()
            default: break
            }
        }
        var repaired = trimmed
        if inString { repaired += escaped ? "\\\"" : "\"" }
        for _ in 0..<3 {
            if let json = decode(repaired + String(stack.reversed())) { return json }
            while let last = repaired.last, ",: \n\t".contains(last) { repaired.removeLast() }
            if let json = decode(repaired + String(stack.reversed())) { return json }
            if repaired.last == "\"", let open = repaired.dropLast().lastIndex(of: "\"") {
                repaired = String(repaired[..<open])
            } else { break }
        }
        return nil
    }

    private static func decode(_ s: String) -> JSON? { try? JSONDecoder().decode(JSON.self, from: Data(s.utf8)) }
}
