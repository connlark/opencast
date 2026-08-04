import Foundation
@testable import OpenCastTranscription

final class DictionaryRemoteModelTransport: OpenCastRemoteModelTransport, @unchecked Sendable {
    private let dataResponses: [URL: OpenCastRemoteModelDataResponse]
    private let downloadBodies: [URL: Data]

    init(
        dataResponses: [URL: OpenCastRemoteModelDataResponse] = [:],
        downloadBodies: [URL: Data] = [:]
    ) {
        self.dataResponses = dataResponses
        self.downloadBodies = downloadBodies
    }

    func data(from url: URL) async throws -> OpenCastRemoteModelDataResponse {
        dataResponses[url] ?? OpenCastRemoteModelDataResponse(
            data: Data(),
            response: OpenCastRemoteModelResponse(statusCode: 404)
        )
    }

    func download(
        from url: URL,
        to destinationURL: URL,
        expectedByteCount: Int64,
        maximumByteCount: Int64,
        progress: OpenCastRemoteModelDownloadProgressHandler?
    ) async throws -> OpenCastRemoteModelResponse {
        guard let data = downloadBodies[url] else {
            return OpenCastRemoteModelResponse(statusCode: 404)
        }
        let byteCount = Int64(data.count)
        guard byteCount <= expectedByteCount,
              byteCount <= maximumByteCount else {
            throw OpenCastTranscriptionError.invalidRemoteManifest(
                "downloaded byte count for \(url.absoluteString) exceeded configured limits"
            )
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destinationURL)
        progress?(byteCount)
        return OpenCastRemoteModelResponse(statusCode: 200)
    }
}
