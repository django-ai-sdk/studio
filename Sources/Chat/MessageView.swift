import SwiftUI

/// One chat message, laid out like the web app's MessageItem, in Apple style:
/// - user: right-aligned bubble, attachments above it;
/// - assistant: no bubble, full column width, in the order the assistant worked — chain of thought
///   (reasoning + tool calls), artifacts, the answer (markdown, citation markers), then files,
///   errors, oversight notices, sources, hover actions and follow-up suggestions.
struct MessageView: View {
    let message: ChatMessage
    var streaming = false
    /// The conversation's last message (shows follow-up suggestions). Passed in by the list so a
    /// row never reads `chat.messages`, which would re-render every row per streamed token.
    var isLast = false

    var body: some View {
        if message.role == "user" {
            UserMessage(message: message)
        } else {
            AssistantMessage(message: message, streaming: streaming, showSuggestions: isLast && !streaming)
        }
    }
}

// MARK: User

private struct UserMessage: View {
    let message: ChatMessage

    var body: some View {
        let files = message.parts.filter { Part.type($0) == "file" }.map(FileRef.init(json:))
        VStack(alignment: .trailing, spacing: 8) {
            if !files.isEmpty { FileChips(files: files, alignment: .trailing) }
            if !message.text.isEmpty {
                HStack {
                    Spacer(minLength: Platform.isMac ? 120 : 48)
                    Text(message.text)
                        .chatBodyFont()
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.fill.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .accessibilityLabel("You: \(message.text)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(message.text) }
        }
    }
}

// MARK: Assistant

private struct AssistantMessage: View {
    let message: ChatMessage
    let streaming: Bool
    let showSuggestions: Bool
    /// Only for actions (suggestion chips send); the body never reads its state.
    @Environment(ChatStore.self) private var chat: ChatStore?
    /// Thread side panel; citations open its Sources tab like the web app. Nil outside ChatView (sheet fallback).
    @Environment(ThreadPanelState.self) private var panel: ThreadPanelState?
    /// The enclosing link handler (the thread panel's browser), read before the answer's own override.
    @Environment(\.openURL) private var inheritedOpenURL
    @State private var hovering = false
    @State private var copied = false
    @State private var citationFocus: CitationFocus?

    /// Everything the view reads from the parts, worked out once per render.
    private struct Derived {
        var parts: [JSON] = []
        var citations: Citations?
        var steps: [(index: Int, part: JSON)] = []
        /// Keyed by tool call id (else part index), so rows keep their state while parts stream in.
        var artifacts: [(id: String, part: JSON)] = []
        var answer = ""
        var plainAnswer = ""
        var sources: [SourceItem] = []
        var errors: [(message: String, ref: String?, retryable: Bool)] = []
        var finishReason: String?
        var files: [FileRef] = []
        var notices: [Oversight.Line] = []
        var suggestions: [String] = []
        var isEmpty: Bool { steps.isEmpty && artifacts.isEmpty && answer.isEmpty && files.isEmpty && errors.isEmpty }

        init(message: ChatMessage, showSuggestions: Bool) {
            parts = Part.dedupTools(message.parts)
            citations = Citations(parts: parts)

            // Reasoning worth showing and every tool call but the citations one, with the part's
            // index in `message.parts` (for thinking time); duplicate tool parts keep the best state.
            let bestTools = Dictionary(parts.filter(Part.isTool).compactMap { p in p["toolCallId"]?.string.map { ($0, p) } },
                                       uniquingKeysWith: { a, _ in a })
            var seen = Set<String>()
            steps = message.parts.enumerated().compactMap { i, p in
                if Part.isTool(p) {
                    guard !Part.isCitations(p) else { return nil }
                    guard let id = p["toolCallId"]?.string else { return (i, p) }
                    guard seen.insert(id).inserted else { return nil }
                    return (i, bestTools[id] ?? p)
                }
                if Part.type(p) == "reasoning", !(p["text"]?.string ?? "").isEmpty || Part.isRunning(p) { return (i, p) }
                return nil
            }
            artifacts = parts.enumerated().compactMap { i, p in
                guard Part.isArtifact(p), !Part.isCitations(p) else { return nil }
                return (p["toolCallId"]?.string ?? "part-\(i)", p)
            }

            var n = 0
            sources = parts.compactMap { p in
                let t = Part.type(p)
                guard t == "source-url" || t == "source-document" else { return nil }
                n += 1
                let number = p["providerMetadata"]?["citation"]?["index"]?.number.map(Int.init) ?? n
                let url = p["url"]?.string.flatMap(URL.init(string:))
                let title = p["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? p["filename"]?.string
                    ?? url?.host() ?? "Source \(number)"
                return SourceItem(id: p["sourceId"]?.string ?? "\(n)", number: number, title: title,
                                  url: url, isDocument: t == "source-document")
            }

            // The answer: oversight's replacement if any, else the text parts, with citation markers.
            let texts = parts.filter { Part.type($0) == "text" }.compactMap { $0["text"]?.string }
            if let replaced = Oversight.replacementText(parts) {
                answer = replaced
                plainAnswer = replaced
            } else {
                plainAnswer = texts.joined(separator: "\n\n")
                if let citations, !citations.citations.isEmpty {
                    answer = citations.annotate(texts.joined())
                } else {
                    answer = sources.isEmpty ? plainAnswer : AssistantMessage.linkLegacyCitations(plainAnswer, count: sources.count)
                }
            }

            finishReason = message.meta?["finish_reason"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            errors = parts.compactMap { p -> (String, String?, Bool)? in
                switch Part.type(p) {
                case "data-error":
                    let d = p["data"]
                    return (d?["message"]?.string ?? Part.friendlyError(d?["code"]?.string ?? "Something went wrong."),
                            d?["ref"]?.string, d?["retryable"]?.bool ?? false)
                case "error":
                    return (p["errorText"]?.string ?? p["text"]?.string ?? "An error occurred.", nil, false)
                default: return nil
                }
            }
            if errors.isEmpty, finishReason == "error" || message.meta?["has_errors"]?.bool == true {
                errors.append(("Something went wrong while answering.", nil, true))
            }
            files = parts.filter { Part.type($0) == "file" }.map(FileRef.init(json:))
            notices = Oversight.lines(parts)
            if showSuggestions {
                suggestions = parts.last(where: { Part.type($0) == "data-suggestions" })?["data"]?["suggestions"]?.array?
                    .compactMap(\.string) ?? []
            }
        }
    }

    var body: some View {
        let d = Derived(message: message, showSuggestions: showSuggestions)
        VStack(alignment: .leading, spacing: 16) {
            if d.isEmpty && streaming {
                TypingIndicator()
            }
            if !d.steps.isEmpty {
                ChainOfThoughtView(messageID: message.id, steps: d.steps, streaming: streaming)
            }
            ForEach(d.artifacts, id: \.id) { artifact in
                ArtifactView(part: artifact.part)
            }
            if !d.answer.isEmpty {
                MarkdownText(markdown: d.answer)
                    .environment(\.openURL, OpenURLAction { openLink($0, sources: d.sources) })
            }
            if !d.files.isEmpty { FileChips(files: d.files, alignment: .leading) }
            ForEach(Array(d.errors.enumerated()), id: \.offset) { _, e in
                ErrorCallout(message: e.message, reference: e.ref, retryable: e.retryable)
            }
            if let reason = d.finishReason, !["stop", "error", "tool-calls", "tool_calls"].contains(reason) {
                Label(reason == "abort" ? "Stopped" : "Stopped: \(reason.replacingOccurrences(of: "-", with: " "))",
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !d.notices.isEmpty { OversightBanners(lines: d.notices) }
            if !d.sources.isEmpty { SourcesRow(sources: d.sources) }
            if !streaming && !d.isEmpty { actions(d).padding(.top, -8) }
            if !d.suggestions.isEmpty, let chat {
                SuggestionChips(suggestions: d.suggestions) { chat.send($0) }
            }
        }
        .chatBodyFont()
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if !d.plainAnswer.isEmpty {
                Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(Self.plainText(d.plainAnswer)) }
                Button("Copy as Markdown", systemImage: "doc.plaintext") { Pasteboard.copy(d.plainAnswer) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Copy message") { Pasteboard.copy(Self.plainText(d.plainAnswer)) }
        .sheet(item: $citationFocus) { focus in
            if let citations = d.citations { CitationsSheet(data: citations, focus: focus) }
        }
        .animation(.snappy(duration: 0.2), value: d.isEmpty)
    }

    /// Copy (and the cited-sources button) below the answer; on macOS the copy button shows on
    /// hover, on iOS (no hover) it is always visible.
    private func actions(_ d: Derived) -> some View {
        HStack(spacing: 2) {
            Button {
                Pasteboard.copy(d.plainAnswer)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: Platform.isMac ? 24 : 32, height: Platform.isMac ? 22 : 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Copy")
            .accessibilityLabel(copied ? "Copied" : "Copy message")
            .opacity(hovering || copied || !Platform.isMac ? 1 : 0)
            .disabled(d.plainAnswer.isEmpty)

            if let citations = d.citations, !citations.citedSources.isEmpty {
                let n = citations.citedSources.count
                Button { if let panel { panel.open(.sources) } else { citationFocus = .all } } label: {
                    Label("\(n) \(n == 1 ? "source" : "sources")", systemImage: "books.vertical")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Show the sources this answer cites")
            }
            Spacer()
        }
        .frame(height: Platform.isMac ? 22 : 32)
    }

    private func openLink(_ url: URL, sources: [SourceItem]) -> OpenURLAction.Result {
        switch url.scheme {
        case "studio-cite":
            if let i = Int(url.host() ?? "") {
                if let panel { panel.showCitation(message: message.id, index: i) } else { citationFocus = .citation(i) }
            }
            return .handled
        case "studio-source":
            let n = Int(url.host() ?? "") ?? 0
            if let source = sources.first(where: { $0.number == n }), let link = source.url {
                guard ["http", "https"].contains(link.scheme?.lowercased() ?? "") else { return .systemAction(link) }
                inheritedOpenURL(link)
            }
            return .handled
        default:
            // Web links go to the enclosing handler (the panel's browser); `.systemAction` would bypass it.
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .systemAction }
            inheritedOpenURL(url)
            return .handled
        }
    }

    /// Markdown as plain text: inline markup (emphasis, links, code) dropped, line breaks kept.
    nonisolated static func plainText(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: markdown, options: options) else { return markdown }
        return String(attributed.characters)
    }

    /// `[3]` markers (answers stored with inline citations) → superscript links to the source.
    nonisolated static func linkLegacyCitations(_ text: String, count: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,3})\](?![(\[:])"#) else { return text }
        var out = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: out), let numRange = Range(match.range(at: 1), in: out),
                  let n = Int(out[numRange]), n >= 1, n <= count else { continue }
            out.replaceSubrange(whole, with: "[\(Citations.superscript(String(n)))](studio-source://\(n))")
        }
        return out
    }
}
