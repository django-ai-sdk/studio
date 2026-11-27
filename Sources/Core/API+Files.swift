import Foundation

// Thread files (the web app's chat uploads): every attachment, images included, is uploaded
// to the thread (`POST /api/memories/thread/{id}/files`), processed server-side, and then
// referenced from the user message as a `file` part carrying `providerMetadata.sdk.documentId`.
// The server only trusts that id (validated against the thread's files) and decides itself
// whether an image goes inline to a vision model or is described / searched via RAG.

struct UploadSettings: Decodable, Sendable {
    let max_upload_size: Int
    let allowed_mime_types: [String]
}

/// A thread file (`DocumentOut`), trimmed to what the client uses.
struct ThreadFile: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let file_name: String
    let file_size: Int
    let content_type: String
    let status: String
    let error: String?
    let processing_step: String?
    let created_at: String
}

/// Upload response (`DocumentUploadResponse`) and status poll (`DocumentStatusOut`).
struct FileStatus: Decodable, Sendable {
    let id: String
    let status: String
    let error: String?
    let processing_step: String?

    /// `pending | processing | completed | failed | cancelled`
    var inFlight: Bool { status == "pending" || status == "processing" }
    var failed: Bool { status == "failed" || status == "cancelled" }
}

extension API {
    func uploadSettings() async throws -> UploadSettings {
        try await json(UploadSettings.self, "GET", "/api/memories/settings")
    }

    func threadFiles(thread: String) async throws -> [ThreadFile] {
        try await json([ThreadFile].self, "GET", "/api/memories/thread/\(thread)/files")
    }

    func fileStatus(thread: String, file: String) async throws -> FileStatus {
        try await json(FileStatus.self, "GET", "/api/memories/thread/\(thread)/files/\(file)/status")
    }

    func deleteThreadFile(thread: String, file: String) async throws {
        let (data, status) = try await send("DELETE", "/api/memories/thread/\(thread)/files/\(file)")
        guard (200..<300).contains(status) else { throw Self.error(data, status) }
    }

    /// Path of a thread file's bytes (raster images render inline, the rest downloads).
    func threadFilePath(thread: String, file: String) -> String {
        "/api/memories/thread/\(thread)/files/\(file)/download"
    }

    /// Multipart upload of one file; `progress` gets 0…1 as the body is sent.
    func uploadThreadFile(thread: String, name: String, mimeType: String, data: Data,
                          progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> FileStatus {
        let boundary = "Studio-\(UUID().uuidString)"
        let safeName = name.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r\n", with: " ")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = try request("POST", "/api/memories/thread/\(thread)/files")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (respData, response) = try await session.upload(for: req, from: body,
                                                             delegate: UploadProgressDelegate(progress))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw UploadError(status: status, message: Self.error(respData, status).message)
        }
        do { return try JSONDecoder().decode(FileStatus.self, from: respData) } catch {
            throw APIError(message: "Unexpected upload response: \(error)")
        }
    }
}

/// A rejected upload; 409 means the thread already holds the same file.
struct UploadError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// Reports upload progress in steps of at least 1% (and the final 100%), not per sent chunk.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    /// Guards `lastReported`; the delegate queue may call from any thread.
    private let lock = NSLock()
    private var lastReported = -1.0

    init(_ onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        let report = lock.withLock {
            guard fraction >= 1 ? lastReported < 1 : fraction - lastReported >= 0.01 else { return false }
            lastReported = fraction
            return true
        }
        if report { onProgress(fraction) }
    }
}
