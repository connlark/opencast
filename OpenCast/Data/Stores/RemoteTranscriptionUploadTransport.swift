import Foundation

nonisolated struct RemoteTranscriptionUploadPartPutResult: Sendable, Equatable {
    var statusCode: Int
    var etag: String?
}

nonisolated protocol RemoteTranscriptionUploadTransport: Sendable {
    func uploadPart(
        partNumber: Int,
        fileURL: URL,
        to url: URL
    ) async throws -> RemoteTranscriptionUploadPartPutResult
    func cancelOutstandingTasks() async
    func finishTasksAndInvalidate()
}
