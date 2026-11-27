#if os(macOS)
import AppKit
#else
import PhotosUI
import UIKit
#endif
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
typealias ComposerPasteboard = NSPasteboard
#else
typealias ComposerPasteboard = UIPasteboard
#endif

/// Files attached to the next message, mirroring the web app: every file (images too) is
/// uploaded to the thread's files, processed server-side, and once ready rides along with
/// the next user message as a `file` part whose `providerMetadata.sdk.documentId` names
/// the thread file. The server decides whether an image goes inline (vision agents) or is
/// described/searched (RAG). Upload needs a thread, so the first file creates one.
@Observable @MainActor
final class AttachmentStore {
    enum State: Equatable {
        case pending
        case uploading(Double)
        case processing(String?)
        case ready
        case failed(String)

        var inFlight: Bool {
            switch self {
            case .pending, .uploading, .processing: true
            case .ready, .failed: false
            }
        }
    }

    struct Item: Identifiable {
        let id = UUID()
        let name: String
        let size: Int
        let mimeType: String
        /// Kept for retries; dropped once the server has the file.
        var data: Data?
        var thumbnail: PlatformImage?
        var state: State = .pending
        var docID: String?
        /// False when the server already had this file (dedupe): removing the chip keeps it.
        var ownsFile = true

        var isImage: Bool { mimeType.hasPrefix("image/") }
    }

    private(set) var items: [Item] = []
    /// Last validation problem ("x.zip: file type not allowed"), shown above the input.
    var notice: String?
    private(set) var settings: UploadSettings?
    private var threadID: String?
    private var threadTask: Task<String, Error>?
    /// Running upload per item. The token tells a superseded (cancelled) task apart from the
    /// one that replaced it, so it can neither clear the new handle nor write into the item.
    private var tasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Processing polls (1.5 s apart) before giving up: about 3 minutes.
    private static let maxPolls = 120

    /// Any upload still running: sending waits for it.
    var busy: Bool { items.contains { $0.state.inFlight } }
    var hasReady: Bool { items.contains { $0.state == .ready } }

    /// Picker filter from the server's allowed MIME types.
    var allowedContentTypes: [UTType] {
        let types = (settings?.allowed_mime_types ?? []).compactMap { UTType(mimeType: $0) }
            + (settings?.allowed_mime_types.contains("text/markdown") == true ? [UTType(filenameExtension: "md")].compactMap { $0 } : [])
        return types.isEmpty ? [.item] : types
    }

    func loadSettings(api: API) async {
        guard settings == nil else { return }
        settings = try? await api.uploadSettings()
    }

    // MARK: Adding

    func add(urls: [URL], chat: ChatStore) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                notice = "\(url.lastPathComponent) can't be read"
                continue
            }
            add(data: data, name: url.lastPathComponent, chat: chat)
        }
    }

    func add(data: Data, name: String, chat: ChatStore) {
        guard chat.agent?.file_upload == true else {
            notice = "\(chat.agent?.name ?? "This agent") can't take files"
            return
        }
        let mime = Self.mimeType(for: name)
        if let max = settings?.max_upload_size, max > 0, data.count > max {
            notice = "\(name) is too large (max \(max / (1024 * 1024)) MB)"
            return
        }
        if let allowed = settings?.allowed_mime_types, !allowed.isEmpty, !allowed.contains(mime) {
            notice = "\(name): file type not allowed"
            return
        }
        notice = nil
        var item = Item(name: name, size: data.count, mimeType: mime, data: data)
        item.thumbnail = mime.hasPrefix("image/") ? PlatformImage(data: data) : nil
        items.append(item)
        start(item.id, chat: chat)
    }

    /// Content types the chat accepts as drops.
    static var dropTypes: [UTType] {
        #if os(macOS)
        [.fileURL, .image]
        #else
        // Files/Photos drags on iPad carry typed data, not file URLs.
        [.fileURL, .image, .data]
        #endif
    }

    #if os(macOS)
    /// Pasteboard → attachments. Returns false when it holds no files or images
    /// (then the text view pastes text as usual).
    func paste(from pasteboard: NSPasteboard, chat: ChatStore) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            add(urls: urls, chat: chat)
            return true
        }
        // Screenshots/copied images; text that also carries an image (rich text) stays text.
        guard pasteboard.string(forType: .string) == nil,
              let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return false }
        add(data: png, name: "Pasted Image \(Self.stamp).png", chat: chat)
        return true
    }
    #else
    /// Pasteboard → attachments (images and file URLs). Returns false when there are none.
    func paste(from pasteboard: UIPasteboard, chat: ChatStore) -> Bool {
        if let urls = pasteboard.urls?.filter(\.isFileURL), !urls.isEmpty {
            add(urls: urls, chat: chat)
            return true
        }
        guard pasteboard.hasImages, let images = pasteboard.images, !images.isEmpty else { return false }
        for (i, image) in images.enumerated() {
            guard let png = image.pngRepresentation else { continue }
            let suffix = images.count > 1 ? " \(i + 1)" : ""
            add(data: png, name: "Pasted Image \(Self.stamp)\(suffix).png", chat: chat)
        }
        return true
    }

    /// Photos from the photo library picker; HEIC and other formats become JPEG.
    func add(photos: [PhotosPickerItem], chat: ChatStore) {
        let stamp = Self.stamp
        for (i, photo) in photos.enumerated() {
            Task {
                guard let data = try? await photo.loadTransferable(type: Data.self) else {
                    notice = "A photo couldn't be loaded"
                    return
                }
                let type = photo.supportedContentTypes.first { $0.conforms(to: .image) }
                guard let (bytes, ext) = Self.normalizedImage(data, type: type) else {
                    notice = "A photo couldn't be read"
                    return
                }
                let suffix = photos.count > 1 ? " \(i + 1)" : ""
                add(data: bytes, name: "Photo \(stamp)\(suffix).\(ext)", chat: chat)
            }
        }
    }

    /// Image bytes in a format the server takes (JPEG/PNG/GIF/WebP kept, the rest re-encoded as JPEG).
    nonisolated static func normalizedImage(_ data: Data, type: UTType?) -> (Data, String)? {
        if let type, let ext = type.preferredFilenameExtension,
           [UTType.jpeg, .png, .gif, .webP].contains(where: { type.conforms(to: $0) }) {
            return (data, ext == "jpeg" ? "jpg" : ext)
        }
        guard let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) else { return nil }
        return (jpeg, "jpg")
    }
    #endif

    private static var stamp: String {
        Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: ".")
    }

    /// Files (or raw images) dropped anywhere on the chat.
    func drop(_ providers: [NSItemProvider], chat: ChatStore) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.add(urls: [url], chat: chat) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                let name = provider.suggestedName ?? "Dropped Image"
                provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in self.add(data: data, name: name.hasSuffix(".png") ? name : name + ".png", chat: chat) }
                }
            } else {
                #if os(iOS)
                handled = loadData(from: provider, chat: chat) || handled
                #endif
            }
        }
        return handled
    }

    #if os(iOS)
    /// Any other typed data (Files/Photos drags on iPad); images are normalized for upload.
    private func loadData(from provider: NSItemProvider, chat: ChatStore) -> Bool {
        guard let typeID = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .data) == true
        }) else { return false }
        let type = UTType(typeID)
        let base = provider.suggestedName ?? "Dropped File"
        _ = provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
            guard let data else { return }
            var bytes = data
            var name = base
            if type?.conforms(to: .image) == true, let (normalized, ext) = Self.normalizedImage(data, type: type) {
                bytes = normalized
                if (name as NSString).pathExtension.isEmpty || normalized != data {
                    name = (name as NSString).deletingPathExtension + "." + ext
                }
            } else if (name as NSString).pathExtension.isEmpty, let ext = type?.preferredFilenameExtension {
                name += "." + ext
            }
            Task { @MainActor in self.add(data: bytes, name: name, chat: chat) }
        }
        return true
    }
    #endif

    // MARK: Lifecycle

    func retry(_ id: UUID, chat: ChatStore) {
        tasks.removeValue(forKey: id)?.task.cancel()
        guard let i = index(id) else { return }
        if items[i].ownsFile, let doc = items[i].docID, let thread = threadID {
            Task { try? await chat.api.deleteThreadFile(thread: thread, file: doc) }
        }
        items[i].docID = nil
        items[i].ownsFile = true
        items[i].state = .pending
        start(id, chat: chat)
    }

    /// Removes the chip; a file already on the server is deleted from the thread (as on the web).
    func remove(_ id: UUID, chat: ChatStore) {
        tasks.removeValue(forKey: id)?.task.cancel()
        guard let i = index(id) else { return }
        if items[i].ownsFile, let doc = items[i].docID, let thread = threadID {
            Task { try? await chat.api.deleteThreadFile(thread: thread, file: doc) }
        }
        items.remove(at: i)
    }

    /// The ready files as UIMessage `file` parts, removed from the tray. Failed ones stay.
    func takeReadyParts(api: API) -> [JSON] {
        guard let thread = threadID else { return [] }
        let ready = items.filter { $0.state == .ready && $0.docID != nil }
        items.removeAll { $0.state == .ready && $0.docID != nil }
        return ready.map { item in
            let url = api.url(api.threadFilePath(thread: thread, file: item.docID!))?.absoluteString ?? ""
            return .object([
                "type": .string("file"),
                "mediaType": .string(item.mimeType),
                "filename": .string(item.name),
                "url": .string(url),
                "providerMetadata": .object(["sdk": .object(["documentId": .string(item.docID!)])]),
            ])
        }
    }

    /// Clears the tray when the chat switches thread (not while our own upload creates one).
    func threadDidChange(to id: String?) {
        guard threadTask == nil, id != threadID else { return }
        tasks.values.forEach { $0.task.cancel() }
        tasks = [:]
        items = []
        notice = nil
        threadID = nil
    }

    // MARK: Upload

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func isCurrent(_ id: UUID, _ token: UUID) -> Bool { tasks[id]?.token == token }

    /// Changes an item only for the upload task that currently owns it.
    private func update(_ id: UUID, _ token: UUID, _ change: (inout Item) -> Void) {
        guard isCurrent(id, token), let i = index(id) else { return }
        change(&items[i])
    }

    private func start(_ id: UUID, chat: ChatStore) {
        tasks[id]?.task.cancel()
        let token = UUID()
        // Main-actor task: it can't run before the handle is stored below.
        tasks[id] = (token, Task { await upload(id, token: token, chat: chat) })
    }

    /// One thread for all files, also when several are added before it exists.
    private func thread(_ chat: ChatStore) async throws -> String {
        if let threadID { return threadID }
        if let threadTask { return try await threadTask.value }
        let task = Task { try await chat.ensureThread() }
        threadTask = task
        defer { threadTask = nil }
        let id = try await task.value
        threadID = id
        return id
    }

    private func upload(_ id: UUID, token: UUID, chat: ChatStore) async {
        defer { if isCurrent(id, token) { tasks[id] = nil } }
        guard let item = items.first(where: { $0.id == id }), let data = item.data else { return }
        var uploaded: (thread: String, doc: String, owned: Bool)?
        do {
            let thread = try await thread(chat)
            try Task.checkCancellation()
            update(id, token) { $0.state = .uploading(0) }
            var status: FileStatus
            var owned = true
            do {
                // Progress arrives on a URLSession queue: keep only the newest value and apply
                // them in order from one task instead of a main-actor Task per callback.
                let (progress, sink) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
                let progressTask = Task {
                    for await fraction in progress {
                        update(id, token) {
                            if case .uploading(let old) = $0.state, fraction > old { $0.state = .uploading(fraction) }
                        }
                    }
                }
                defer { sink.finish(); progressTask.cancel() }
                status = try await chat.api.uploadThreadFile(
                    thread: thread, name: item.name, mimeType: item.mimeType, data: data
                ) { _ = sink.yield($0) }
            } catch let error as UploadError where error.status == 409 {
                // The thread already has this file (the server dedupes by content): attach that one.
                guard let existing = try await chat.api.threadFiles(thread: thread)
                    .first(where: { $0.file_name == item.name && $0.file_size == item.size })
                else { throw error }
                owned = false
                status = FileStatus(id: existing.id, status: existing.status, error: existing.error,
                                    processing_step: existing.processing_step)
            }
            uploaded = (thread, status.id, owned)
            try Task.checkCancellation()
            guard isCurrent(id, token), index(id) != nil else { throw CancellationError() }
            update(id, token) { $0.ownsFile = owned; $0.docID = status.id; $0.data = nil }
            uploaded = nil // The item references the file now; remove/retry delete it.
            var polls = 0
            while status.inFlight {
                guard polls < Self.maxPolls else { throw ProcessingTimeout() }
                polls += 1
                update(id, token) { $0.state = .processing(status.processing_step) }
                try await Task.sleep(for: .seconds(1.5))
                status = try await chat.api.fileStatus(thread: thread, file: status.id)
            }
            update(id, token) {
                $0.state = status.failed ? .failed(status.error.flatMap { $0.isEmpty ? nil : $0 } ?? "Processing failed") : .ready
                // Re-upload on retry needs the bytes again.
                if status.failed { $0.data = data }
            }
        } catch {
            if let uploaded, uploaded.owned {
                // Removed or retried just as the upload finished: nothing references that file.
                Task { try? await chat.api.deleteThreadFile(thread: uploaded.thread, file: uploaded.doc) }
            }
            if !Task.isCancelled {
                update(id, token) { $0.state = .failed(error.localizedDescription); $0.data = data }
            }
        }
    }

    private struct ProcessingTimeout: LocalizedError {
        var errorDescription: String? { "Processing timed out" }
    }

    // MARK: Helpers

    private static let mimeByExtension = [
        "md": "text/markdown", "markdown": "text/markdown", "txt": "text/plain", "csv": "text/csv",
        "json": "text/json", "pdf": "application/pdf", "png": "image/png", "jpg": "image/jpeg",
        "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
    ]

    static func mimeType(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return mimeByExtension[ext] ?? UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}

// MARK: - Views

/// One attachment in the composer tray: thumbnail/icon, name, size or state, remove/retry.
/// A failed chip's thumbnail becomes the Retry button (clear of the remove badge's hit area).
/// VoiceOver: the chip is a container of "name, state", Retry and Remove.
struct AttachmentChip: View {
    let item: AttachmentStore.Item
    let onRemove: () -> Void
    let onRetry: () -> Void

    /// iOS: 44pt tap areas around the small controls; their look and the layout stay the same.
    private static let hitSize: CGFloat = Platform.isMac ? 0 : 44

    var body: some View {
        HStack(spacing: 8) {
            thumbnail
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .help(subtitle)
            }
            .frame(maxWidth: 150, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.name), \(subtitle)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button("Remove \(item.name)", systemImage: "xmark.circle.fill", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(RemoveBadgeStyle(hitSize: Self.hitSize))
                .help("Remove")
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var thumbnail: some View {
        let shaped = preview
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay { progressOverlay }
        if isFailed {
            Button(action: onRetry) {
                shaped
                    .overlay {
                        Image(systemName: "arrow.clockwise")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                            .background(.regularMaterial.opacity(0.85),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .frame(minWidth: Self.hitSize, minHeight: Self.hitSize)
                    .contentShape(Rectangle())
                    .padding(Platform.isMac ? 0 : -5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry \(item.name)")
            .help("Retry upload")
        } else {
            shaped.accessibilityHidden(true)
        }
    }

    #if os(iOS)
    /// SF Symbol for a file type (iOS has no per-type Finder icons).
    static func symbol(for mimeType: String) -> String {
        guard let type = UTType(mimeType: mimeType) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .commaSeparatedText) { return "tablecells" }
        if type.conforms(to: .json) || type.conforms(to: .sourceCode) { return "curlybraces" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
    #endif

    private var isFailed: Bool { if case .failed = item.state { true } else { false } }

    @ViewBuilder private var preview: some View {
        if let thumbnail = item.thumbnail {
            Image(platformImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .opacity(item.state.inFlight ? 0.5 : 1)
        } else {
            #if os(macOS)
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(mimeType: item.mimeType) ?? .data))
                .resizable()
                .aspectRatio(contentMode: .fit)
            #else
            Image(systemName: Self.symbol(for: item.mimeType))
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background.secondary)
            #endif
        }
    }

    @ViewBuilder private var progressOverlay: some View {
        switch item.state {
        case .uploading(let fraction):
            ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
        case .pending, .processing:
            ProgressView().controlSize(.small)
        case .ready, .failed:
            EmptyView()
        }
    }

    private var subtitle: String {
        let size = Int64(item.size).formatted(.byteCount(style: .file))
        switch item.state {
        case .pending: return "Waiting…"
        case .uploading(let fraction): return "Uploading \(Int(fraction * 100))%"
        case .processing(let step):
            switch step {
            case "anydoc", "ocr": return "Reading document…"
            case "extracting": return "Extracting facts…"
            default: return "Processing…"
            }
        case .ready: return size
        case .failed(let message): return message
        }
    }
}

/// The chip's "x" badge, sitting on its top-right corner. On iOS the tap area is `hitSize`
/// square around the badge without moving it.
private struct RemoveBadgeStyle: ButtonStyle {
    let hitSize: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let glyph: CGFloat = Platform.isMac ? 15 : 20
        let box = max(hitSize, glyph)
        configuration.label
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .secondary)
            .font(.system(size: glyph))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .frame(width: box, height: box)
            .contentShape(Rectangle())
            // Same badge position (overhanging the corner by 6pt) whatever the tap box size.
            .offset(x: (box - glyph) / 2 + 6, y: -(box - glyph) / 2 - 6)
    }
}

/// Dashed drag-over affordance for a drop zone.
struct AttachmentDropOverlay: View {
    let enabled: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .foregroundStyle(enabled ? Color.accentColor : .red)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                Label(enabled ? "Drop to attach" : "File upload is not enabled for this agent",
                      systemImage: enabled ? "arrow.down.doc" : "nosign")
                    .font(.headline)
                    .foregroundStyle(enabled ? Color.accentColor : .red)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}
