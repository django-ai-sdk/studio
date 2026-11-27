#if os(macOS)
import AppKit
#else
import PhotosUI
import UIKit
#endif
import SwiftUI

/// Floating message input: attachment tray, multi-line field, attach button, agent menu, send/stop.
/// macOS: Return sends, Shift/Option-Return adds a line; files can be pasted or dropped.
/// iOS: Return adds a line, the Send button (or ⌘Return on a hardware keyboard) sends; the attach
/// menu offers Photos, Files and pasting an image; files can be dropped on iPad.
struct Composer: View {
    @Environment(ChatStore.self) private var chat
    @Environment(AppStore.self) private var app
    let attachments: AttachmentStore
    @State private var draft = ""
    @State private var height: CGFloat = 20
    @State private var importing = false
    #if os(iOS)
    @State private var pickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    #endif

    private var uploadsEnabled: Bool { chat.agent?.file_upload == true }
    private var agentName: String { chat.agent?.name ?? "Agent" }
    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSend: Bool {
        !chat.streaming && chat.agentID != nil && !attachments.busy && (hasText || attachments.hasReady)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.items.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(attachments.items) { item in
                            AttachmentChip(item: item,
                                           onRemove: { attachments.remove(item.id, chat: chat) },
                                           onRetry: { attachments.retry(item.id, chat: chat) })
                        }
                    }
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                }
                .scrollIndicators(.never)
            }
            if let notice = attachments.notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ComposerTextView(text: $draft, height: $height, placeholder: "Message \(agentName)",
                             focusKey: chat.threadID,
                             onSubmit: submit,
                             onPaste: { attachments.paste(from: $0, chat: chat) })
                .frame(height: height)
                .padding(.horizontal, 4)

            HStack(spacing: 6) {
                if uploadsEnabled { attachButton }
                agentPicker
                if attachments.busy && hasText {
                    Text("Waiting for attachments…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                sendButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .composerSurface()
        .fileImporter(isPresented: $importing, allowedContentTypes: attachments.allowedContentTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attachments.add(urls: urls, chat: chat) }
        }
        #if os(iOS)
        .photosPicker(isPresented: $pickingPhotos, selection: $photos, maxSelectionCount: 10,
                      matching: .images, preferredItemEncoding: .compatible)
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            attachments.add(photos: picked, chat: chat)
            photos = []
        }
        #endif
        .task { await attachments.loadSettings(api: chat.api) }
        .onChange(of: chat.restoredDraft, initial: true) { _, restored in
            // A message that couldn't be sent comes back into the field (ahead of anything typed since).
            guard let restored else { return }
            draft = draft.isEmpty ? restored : restored + "\n" + draft
            chat.restoredDraft = nil
        }
    }

    @ViewBuilder private var attachButton: some View {
        #if os(macOS)
        Button("Attach Files", systemImage: "paperclip") { importing = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.system(size: 15))
            .help("Attach files")
        #else
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { pickingPhotos = true }
            Button("Files", systemImage: "folder") { importing = true }
            Button("Paste Image", systemImage: "doc.on.clipboard") {
                let pasteboard = UIPasteboard.general
                if !(pasteboard.hasImages || pasteboard.hasURLs) || !attachments.paste(from: pasteboard, chat: chat) {
                    attachments.notice = "The clipboard has no image or file"
                }
            }
        } label: {
            // 44pt hit area around the 17pt glyph; the negative padding keeps the 32pt row.
            Label("Attach", systemImage: "plus")
                .labelStyle(.iconOnly)
                .font(.body.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .padding(-6)
        .accessibilityLabel("Attach")
        #endif
    }

    @ViewBuilder private var agentPicker: some View {
        if chat.threadID == nil, app.agents.count > 1 {
            Menu {
                ForEach(app.agents) { agent in
                    Toggle(agent.name ?? agent.id, isOn: Binding(
                        get: { chat.agentID == agent.id },
                        set: { if $0 { chat.agentID = agent.id } }))
                }
            } label: {
                #if os(macOS)
                Text(agentName)
                #else
                HStack(spacing: 3) {
                    Text(agentName)
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }
                .font(.subheadline)
                #endif
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .fixedSize()
            .help("Choose agent")
        } else {
            Text(agentName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help(chat.threadID == nil ? "" : "The agent is fixed once the chat has started")
        }
    }

    @ViewBuilder private var sendButton: some View {
        if chat.streaming {
            Button("Stop", systemImage: "stop.fill") { chat.stop() }
                .prominentCircleButton()
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop generating (⌘.)")
        } else {
            Button("Send", systemImage: "arrow.up", action: submit)
                .prominentCircleButton()
                .disabled(!canSend)
                .help(attachments.busy ? "Waiting for attachments to finish" : Platform.isMac ? "Send (Return)" : "Send (⌘Return)")
        }
    }

    private func submit() {
        guard canSend else { return }
        let parts = attachments.takeReadyParts(api: chat.api)
        chat.send(draft, attachments: parts)
        draft = ""
    }
}

/// iOS: widens a button's tap area to 44pt around the system-drawn control without changing
/// its look or layout; taps on the control itself still go to the inner button.
private struct HitAreaButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture { configuration.trigger() }
            .padding(-6)
    }
}

extension View {
    /// Filled circular icon button (send/stop) with the system's own enabled/disabled drawing.
    @ViewBuilder fileprivate func prominentCircleButton() -> some View {
        let base = labelStyle(.iconOnly)
            .fontWeight(.bold)
            .buttonBorderShape(.circle)
        #if os(iOS)
        if #available(iOS 26, *) {
            base.buttonStyle(HitAreaButtonStyle()).buttonStyle(.glassProminent)
        } else {
            base.buttonStyle(HitAreaButtonStyle()).buttonStyle(.borderedProminent)
        }
        #else
        if #available(macOS 26, *) {
            base.buttonStyle(.glassProminent).controlSize(.large)
        } else {
            base.buttonStyle(.borderedProminent).controlSize(.large)
        }
        #endif
    }

    /// Raised rounded surface: Liquid Glass on macOS/iOS 26 (which brings its own depth),
    /// material + hairline + shadow before.
    @ViewBuilder func composerSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if #available(macOS 26, iOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        }
    }
}

// MARK: - Text view

#if os(iOS)
/// iOS input with the same interface as the Mac's NSTextView version: a vertical `TextField`
/// that grows from one to six lines (reporting its height through `height`). Return inserts a
/// newline; ⌘Return on a hardware keyboard submits. `onPaste` is unused (TextField pastes text
/// itself; images come in through the composer's attach menu). `placeholder` is the field's
/// title, so VoiceOver reads it too. The text follows Dynamic Type (17pt at the default size).
struct ComposerTextView: View {
    static let maxLines = 6

    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    /// On iPad, focus is taken whenever this changes, e.g. on switching chats.
    var focusKey: String?
    var onSubmit: () -> Void
    var onPaste: (UIPasteboard) -> Bool
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 17

    init(text: Binding<String>, height: Binding<CGFloat>, placeholder: String, focusKey: String?,
         onSubmit: @escaping () -> Void, onPaste: @escaping (UIPasteboard) -> Bool) {
        _text = text
        _height = height
        self.placeholder = placeholder
        self.focusKey = focusKey
        self.onSubmit = onSubmit
        self.onPaste = onPaste
    }

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .font(.system(size: fontSize))
            .lineLimit(1...Self.maxLines)
            .focused($focused)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { new in
                if abs(height - new) > 0.5 { height = new }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background {
                // Hardware-keyboard send; a zero-size button keeps the shortcut registered.
                Button("Send", action: onSubmit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onChange(of: focusKey) {
                if UIDevice.current.userInterfaceIdiom == .pad { focused = true }
            }
    }
}
#else
/// NSTextView-backed input: grows from one to eight lines, Return submits (unless composing
/// with an input method), Shift/Option-Return inserts a newline, pasting files or images goes
/// to `onPaste`, and file drags fall through to the chat's drop target. `placeholder` shows
/// while empty and is the field's accessibility label. Text is 14pt, scaled with the text size.
struct ComposerTextView: View {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    /// Focus is (re)taken whenever this changes, e.g. on switching chats.
    var focusKey: String?
    var onSubmit: () -> Void
    var onPaste: (NSPasteboard) -> Bool
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 14

    var body: some View {
        InputTextRepresentable(text: $text, height: $height, placeholder: placeholder, fontSize: fontSize,
                               focusKey: focusKey, onSubmit: onSubmit, onPaste: onPaste)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: fontSize))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

private struct InputTextRepresentable: NSViewRepresentable {
    static let maxLines: CGFloat = 8

    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var fontSize: CGFloat
    var focusKey: String?
    var onSubmit: () -> Void
    var onPaste: (NSPasteboard) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = InputTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel(placeholder)
        textView.onPaste = { context.coordinator.parent.onPaste($0) }
        textView.onWidthChange = { [weak coordinator = context.coordinator] in coordinator?.recalculateHeight() }
        textView.string = text

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.accessibilityLabel() != placeholder { textView.setAccessibilityLabel(placeholder) }
        if textView.font?.pointSize != fontSize {
            textView.font = .systemFont(ofSize: fontSize)
            context.coordinator.recalculateHeight()
        }
        if textView.string != text {
            textView.string = text
            context.coordinator.recalculateHeight()
        }
        if context.coordinator.focusKey != focusKey {
            context.coordinator.focusKey = focusKey
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InputTextRepresentable
        weak var textView: NSTextView?
        var focusKey: String?

        init(_ parent: InputTextRepresentable) {
            self.parent = parent
            focusKey = parent.focusKey
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            recalculateHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            if textView.hasMarkedText() { return false }
            parent.onSubmit()
            return true
        }

        func recalculateHeight() {
            guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let line = layout.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: parent.fontSize))
            let used = layout.usedRect(for: container).height
            let target = min(max(used, line), line * InputTextRepresentable.maxLines).rounded(.up)
            if abs(parent.height - target) > 0.5 {
                DispatchQueue.main.async { self.parent.height = target }
            }
        }
    }
}

final class InputTextView: NSTextView {
    var onPaste: ((NSPasteboard) -> Bool)?
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func paste(_ sender: Any?) {
        if onPaste?(.general) == true { return }
        super.paste(sender)
    }

    // Let file drags reach the chat's drop target instead of inserting paths.
    override func updateDragTypeRegistration() { unregisterDraggedTypes() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { window.makeFirstResponder(self) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - lastWidth) > 0.5 {
            lastWidth = newSize.width
            DispatchQueue.main.async { [weak self] in self?.onWidthChange?() }
        }
    }
}
#endif
