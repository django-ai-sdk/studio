#if os(macOS)
import AppKit
#endif
import SwiftUI
import UniformTypeIdentifiers

/// A file from a `file` part or a file artifact.
nonisolated struct FileRef: Hashable {
    let url: String?
    let filename: String
    let mediaType: String

    init(json: JSON) {
        url = json["url"]?.string
        mediaType = json["mediaType"]?.string ?? json["media_type"]?.string ?? ""
        filename = json["filename"]?.string ?? json["name"]?.string
            ?? url.flatMap { URL(string: $0)?.lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? "File"
    }

    var isImage: Bool { mediaType.hasPrefix("image/") }

    var symbol: String {
        if isImage { return "photo" }
        if mediaType == "application/pdf" { return "doc.richtext" }
        if mediaType.hasPrefix("text/") { return "doc.plaintext" }
        if mediaType.contains("sheet") || mediaType.contains("csv") { return "tablecells" }
        if mediaType.hasPrefix("audio/") { return "waveform" }
        if mediaType.hasPrefix("video/") { return "film" }
        return "doc"
    }

    var fileExtension: String {
        let ext = (filename as NSString).pathExtension
        if !ext.isEmpty { return ext.uppercased() }
        return UTType(mimeType: mediaType)?.preferredFilenameExtension?.uppercased() ?? "FILE"
    }


    /// Absolute URL: data:/http(s) as-is, server-relative paths against the API base.
    static func resolve(_ string: String?, base: URL?) -> URL? {
        guard let string, !string.isEmpty else { return nil }
        if string.hasPrefix("data:") || string.hasPrefix("http://") || string.hasPrefix("https://") {
            return URL(string: string)
        }
        return base.flatMap { URL(string: string, relativeTo: $0)?.absoluteURL }
    }
}

/// File parts: image thumbnails (click for a larger preview) and file chips (click to open).
struct FileChips: View {
    let files: [FileRef]
    var alignment: HorizontalAlignment = .trailing
    @Environment(AppStore.self) private var app: AppStore?
    @Environment(\.openURL) private var openURL
    @State private var preview: FileRef?

    var body: some View {
        let images = files.filter(\.isImage)
        let others = files.filter { !$0.isImage }
        VStack(alignment: alignment, spacing: 6) {
            if !images.isEmpty {
                HStack(spacing: 6) {
                    // Offsets: the same file can be attached twice and rows hold no state.
                    ForEach(Array(images.enumerated()), id: \.offset) { _, file in
                        Button { preview = file } label: { Thumbnail(url: url(file), size: 112) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Image \(file.filename)")
                            .help(file.filename)
                    }
                }
            }
            ForEach(Array(others.enumerated()), id: \.offset) { _, file in
                Button {
                    if let u = url(file) { openURL(u) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: file.symbol)
                            .foregroundStyle(.tint)
                            .frame(width: 28, height: 28)
                            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(file.filename).font(.callout).lineLimit(1).truncationMode(.middle)
                            Text(file.fileExtension).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6).padding(.leading, 6).padding(.trailing, 12)
                    .frame(maxWidth: 260, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
                }
                .buttonStyle(.plain)
                .disabled(url(file) == nil)
                .accessibilityLabel("File \(file.filename)")
                .help(file.filename)
            }
        }
        .sheet(item: Binding(get: { preview.map(Identified.init) }, set: { preview = $0?.file })) { item in
            ImagePreview(file: item.file, url: url(item.file))
        }
    }

    private func url(_ file: FileRef) -> URL? { FileRef.resolve(file.url, base: app?.api.base) }

    private struct Identified: Identifiable { let file: FileRef; var id: FileRef { file } }
}

private struct Thumbnail: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if url?.scheme == "data" {
                DecodedImage(source: url?.absoluteString) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView().controlSize(.small)
                }
            } else {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                    default: ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
    }
}

private struct ImagePreview: View {
    let file: FileRef
    let url: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(file.filename).font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            Group {
                if url?.scheme == "data" {
                    DecodedImage(source: url?.absoluteString) { image in
                        image.resizable().scaledToFit()
                    } placeholder: { ProgressView() }
                } else {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: { ProgressView() }
                }
            }
            .padding(12)
        }
        .macSheetFrame(minWidth: 480, idealWidth: 760, minHeight: 360, idealHeight: 600)
    }
}

// MARK: Inline image decoding

/// Decodes base64 / `data:` URL images once per distinct string, off the render path: views show
/// them through `DecodedImage`, which looks them up in `.task(id:)` rather than in `body`.
@MainActor
enum InlineImageCache {
    private static let cache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 64
        return cache
    }()

    /// The image for a `data:` URL string or a bare base64 string; nil when it doesn't decode.
    static func image(for source: String) -> PlatformImage? {
        let key = source as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let data: Data?
        if source.hasPrefix("data:") {
            data = URL(string: source).flatMap { try? Data(contentsOf: $0) }
        } else {
            data = Data(base64Encoded: source, options: .ignoreUnknownCharacters)
        }
        guard let data, let image = PlatformImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// An inline (base64 / `data:`) image, decoded once via `InlineImageCache`.
struct DecodedImage<Content: View, Placeholder: View>: View {
    let source: String?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                content(Image(platformImage: image))
            } else if failed {
                Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
            } else {
                placeholder()
            }
        }
        .task(id: source) {
            let decoded = source.flatMap(InlineImageCache.image(for:))
            image = decoded
            failed = decoded == nil
        }
    }
}
