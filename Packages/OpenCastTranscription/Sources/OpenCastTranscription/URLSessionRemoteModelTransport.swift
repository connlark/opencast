import Foundation

struct URLSessionRemoteModelTransport: OpenCastRemoteModelTransport {
    var session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(from url: URL) async throws -> OpenCastRemoteModelDataResponse {
        let (data, response) = try await session.data(from: url)
        return OpenCastRemoteModelDataResponse(
            data: data,
            response: OpenCastRemoteModelResponse(statusCode: (response as? HTTPURLResponse)?.statusCode)
        )
    }

    func download(
        from url: URL,
        to destinationURL: URL,
        expectedByteCount: Int64,
        maximumByteCount: Int64
    ) async throws -> OpenCastRemoteModelResponse {
        try await Self.streamDownload(
            session: session,
            url: url,
            destinationURL: destinationURL,
            expectedByteCount: expectedByteCount,
            maximumByteCount: maximumByteCount
        )
    }

    @concurrent
    private static func streamDownload(
        session: URLSession,
        url: URL,
        destinationURL: URL,
        expectedByteCount: Int64,
        maximumByteCount: Int64
    ) async throws -> OpenCastRemoteModelResponse {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(from: url)
        let modelResponse = OpenCastRemoteModelResponse(
            statusCode: (response as? HTTPURLResponse)?.statusCode
        )
        guard modelResponse.isSuccessfulHTTPResponse else {
            throw OpenCastTranscriptionError.remoteModelDownloadFailed(url)
        }
        if response.expectedContentLength > maximumByteCount {
            throw OpenCastTranscriptionError.invalidRemoteManifest(
                "declared content length for \(url.absoluteString) exceeds configured limits"
            )
        }

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        var buffer = Data()
        buffer.reserveCapacity(64 * 1_024)
        var byteCount: Int64 = 0

        do {
            defer {
                try? handle.close()
            }

            for try await byte in bytes {
                byteCount += 1
                if byteCount > expectedByteCount || byteCount > maximumByteCount {
                    throw OpenCastTranscriptionError.invalidRemoteManifest(
                        "downloaded byte count for \(url.absoluteString) exceeded configured limits"
                    )
                }
                buffer.append(byte)
                if buffer.count >= 64 * 1_024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    try Task.checkCancellation()
                }
            }

            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }

        return modelResponse
    }
}
