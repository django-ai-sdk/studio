#if os(macOS)
import AppKit
#endif
import SwiftUI
import Textual

struct MarkdownText: View {
    let markdown: String

    #if os(macOS)
    static let bodySize: CGFloat = 14
    #else
    static let bodySize: CGFloat = 17
    #endif

    var body: some View {
        StructuredText(markdown: markdown)
            .textual.paragraphStyle(ChatParagraphStyle())
            .textual.listItemSpacing(.fontScaled(top: 0.4))
            .textual.headingStyle(ChatHeadingStyle())
            .textual.codeBlockStyle(ChatCodeBlockStyle())
            .textual.tableStyle(ChatTableStyle())
            .textual.textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func fenced(_ code: String, language: String?) -> String {
        var longest = 0, run = 0
        for c in code { run = c == "`" ? run + 1 : 0; longest = max(longest, run) }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\(language ?? "")\n\(code)\n\(fence)"
    }
}

struct ChatBodyFont: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var size = MarkdownText.bodySize

    func body(content: Content) -> some View {
        content.font(.system(size: size))
    }
}

extension View {
    func chatBodyFont() -> some View { modifier(ChatBodyFont()) }

    @ViewBuilder func chatPartHitTarget() -> some View {
        #if os(iOS)
        frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        #else
        self
        #endif
    }
}

struct ChatParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(.fontScaled(0.32))
            .textual.blockSpacing(.fontScaled(top: 0.85))
    }
}

struct ChatHeadingStyle: StructuredText.HeadingStyle {
    private static let scales: [CGFloat] = [1.45, 1.3, 1.15, 1.05, 1, 1]

    func makeBody(configuration: Configuration) -> some View {
        let level = min(max(configuration.headingLevel, 1), 6)
        configuration.label
            .textual.fontScale(Self.scales[level - 1])
            .fontWeight(level <= 2 ? .bold : .semibold)
            .textual.blockSpacing(.fontScaled(top: 1.5, bottom: 0.45))
            .accessibilityAddTraits(.isHeader)
    }
}

struct ChatCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        CodeBlockFrame(language: configuration.languageHint, copy: configuration.codeBlock.copyToPasteboard) {
            Overflow {
                configuration.label
                    .textual.lineSpacing(.fontScaled(0.3))
                    .textual.fontScale(0.88)
                    .fixedSize(horizontal: false, vertical: true)
                    .monospaced()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .textual.blockSpacing(.fontScaled(top: 1.0, bottom: 0.3))
    }
}

struct ChatTableStyle: StructuredText.TableStyle {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    func makeBody(configuration: Configuration) -> some View {
        #if os(iOS)
        if sizeClass == .compact {
            StructuredText.OverflowTableStyle(relativeWidth: 2.2).makeBody(configuration: configuration)
        } else {
            StructuredText.DefaultTableStyle().makeBody(configuration: configuration)
        }
        #else
        StructuredText.DefaultTableStyle().makeBody(configuration: configuration)
        #endif
    }
}

struct CodeBlockFrame<Content: View>: View {
    let language: String?
    let copy: () -> Void
    @ViewBuilder let content: Content
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.flatMap { $0.isEmpty ? nil : $0 } ?? "code")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copy()
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Copy code")
                .accessibilityLabel(copied ? "Copied" : "Copy code")
                #if os(iOS)
                .frame(minHeight: 44).contentShape(Rectangle())
                .padding(.vertical, -10)
                #endif
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5))
            Divider()
            content
        }
        .background(Self.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
    }
}

extension CodeBlockFrame {
    static var codeBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor).opacity(0.6)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

enum Pasteboard {
    @MainActor static func copy(_ text: String) { Platform.copy(text) }
}
