import Foundation

protocol OpenCastRemoteModelTransport: Sendable {
    func data(from url: URL) async throws -> OpenCastRemoteModelDataResponse

    func download(
        from url: URL,
        to destinationURL: URL,
        expectedByteCount: Int64,
        maximumByteCount: Int64
    ) async throws -> OpenCastRemoteModelResponse
}
