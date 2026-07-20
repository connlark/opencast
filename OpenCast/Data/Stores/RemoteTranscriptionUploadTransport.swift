import Foundation

/// Outcome of one presigned part PUT: the HTTP status and the ETag header the
/// storage endpoint returned (present on success).
nonisolated struct RemoteTranscriptionUploadPartPutResult: Sendable, Equatable {
    var statusCode: Int
    var etag: String?
}

/// How one part file gets PUT to its presigned URL. The live implementation
/// is a background URLSession per job; tests inject a deterministic fake so
/// the upload session's resume/refresh logic is provable without a server.
nonisolated protocol RemoteTranscriptionUploadTransport: Sendable {
    func uploadPart(
        partNumber: Int,
        fileURL: URL,
        to url: URL
    ) async throws -> RemoteTranscriptionUploadPartPutResult
    func cancelOutstandingTasks() async
    func finishTasksAndInvalidate()
}
