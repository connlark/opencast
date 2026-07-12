import Foundation
import OpenCastCore

struct URLSessionEpisodeAudioDownloader: EpisodeAudioDownloading, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: OpenCastURLSessionFactory.downloadConfiguration())) {
        self.session = session
    }

    @concurrent
    func download(
        from sourceURL: URL,
        to temporaryURL: URL,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        if sourceURL.isFileURL {
            await onResponseMetadata(EpisodeDownloadResponseMetadata(entityTag: nil, lastModified: nil))
            try await copyLocalFile(from: sourceURL, to: temporaryURL, progress: progress)
            return
        }

        do {
            try await downloadRemoteFile(
                from: sourceURL,
                to: temporaryURL,
                resume: resume,
                onResponseMetadata: onResponseMetadata,
                progress: progress
            )
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        }
    }

    @concurrent
    private func downloadRemoteFile(
        from sourceURL: URL,
        to temporaryURL: URL,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        let requestedResumeOffset = max(0, resume?.offset ?? 0)
        let ifRangeValidator: String?
        if let entityTag = resume?.entityTag?.trimmingCharacters(in: .whitespacesAndNewlines),
           entityTag.isEmpty == false,
           entityTag.lowercased().hasPrefix("w/") == false {
            ifRangeValidator = entityTag
        } else if let lastModified = resume?.lastModified?.trimmingCharacters(in: .whitespacesAndNewlines),
                  lastModified.isEmpty == false {
            ifRangeValidator = lastModified
        } else {
            ifRangeValidator = nil
        }
        let resumeOffset = ifRangeValidator == nil ? 0 : requestedResumeOffset
        var request = URLRequest(url: sourceURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
            request.setValue(ifRangeValidator, forHTTPHeaderField: "If-Range")
        }

        let (bytes, response) = try await session.bytes(for: request)
        let normalizedResponse = OpenCastHTTPResponse(response)
        let policy = EpisodeDownloadResumeResponsePolicy.evaluate(
            statusCode: normalizedResponse.statusCode ?? -1,
            resumeOffset: resumeOffset,
            headers: normalizedResponse.headers
        )

        switch policy {
        case .append(let bytesExpected):
            try validateContentEncoding(in: normalizedResponse)
            let metadata = responseMetadata(from: normalizedResponse)
            await onResponseMetadata(
                EpisodeDownloadResponseMetadata(
                    entityTag: metadata.entityTag ?? resume?.entityTag,
                    lastModified: metadata.lastModified ?? resume?.lastModified
                )
            )
            try await write(
                bytes: bytes,
                expectedBytes: bytesExpected,
                initialBytesReceived: resumeOffset,
                appends: true,
                validatesExpectedByteCount: true,
                to: temporaryURL,
                progress: progress
            )
        case .restart(let bytesExpected, false):
            try validateContentEncoding(in: normalizedResponse)
            try Task.checkCancellation()
            try Data().write(to: temporaryURL, options: .atomic)
            try Task.checkCancellation()
            await onResponseMetadata(responseMetadata(from: normalizedResponse))
            let fullResponseExpectedBytes = normalizedResponse.statusCode == 200
                && normalizedResponse.expectedContentLength >= 0
                ? normalizedResponse.expectedContentLength
                : nil
            try await write(
                bytes: bytes,
                expectedBytes: bytesExpected ?? fullResponseExpectedBytes,
                initialBytesReceived: 0,
                appends: false,
                validatesExpectedByteCount: normalizedResponse.statusCode == 206,
                to: temporaryURL,
                progress: progress
            )
        case .restart(_, true):
            try await downloadRemoteFile(
                from: sourceURL,
                to: temporaryURL,
                resume: nil,
                onResponseMetadata: onResponseMetadata,
                progress: progress
            )
        case .fail(let statusCode):
            throw EpisodeDownloadError.invalidHTTPStatus(statusCode)
        }
    }

    @concurrent
    private func copyLocalFile(
        from sourceURL: URL,
        to temporaryURL: URL,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        let data = try Data(contentsOf: sourceURL)
        try Task.checkCancellation()
        try data.write(to: temporaryURL, options: .atomic)
        await progress(Int64(data.count), Int64(data.count))
    }

    @concurrent
    private func write(
        bytes: URLSession.AsyncBytes,
        expectedBytes: Int64?,
        initialBytesReceived: Int64,
        appends: Bool,
        validatesExpectedByteCount: Bool,
        to temporaryURL: URL,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        try Task.checkCancellation()
        let fileHandle = try FileHandle(forWritingTo: temporaryURL)
        defer {
            try? fileHandle.close()
        }

        if appends {
            let fileOffset = try fileHandle.seekToEnd()
            guard fileOffset == UInt64(initialBytesReceived) else {
                throw EpisodeDownloadError.invalidDownloadedRecord
            }
        } else {
            try fileHandle.truncate(atOffset: 0)
        }

        var receivedBytes = initialBytesReceived
        var buffer = Data()
        buffer.reserveCapacity(64 * 1_024)

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            receivedBytes += 1

            guard buffer.count >= 64 * 1_024 else {
                continue
            }

            try fileHandle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
            await progress(receivedBytes, expectedBytes)
        }

        if !buffer.isEmpty {
            try fileHandle.write(contentsOf: buffer)
        }
        if validatesExpectedByteCount,
           let expectedBytes,
           receivedBytes != expectedBytes {
            throw EpisodeDownloadError.interrupted
        }
        await progress(receivedBytes, expectedBytes)
    }

    private nonisolated func responseMetadata(
        from response: OpenCastHTTPResponse
    ) -> EpisodeDownloadResponseMetadata {
        EpisodeDownloadResponseMetadata(
            entityTag: response.headerValue("etag"),
            lastModified: response.headerValue("last-modified")
        )
    }

    private nonisolated func validateContentEncoding(
        in response: OpenCastHTTPResponse
    ) throws {
        guard let contentEncoding = response.headerValue("content-encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              contentEncoding.isEmpty == false,
              contentEncoding.caseInsensitiveCompare("identity") != .orderedSame
        else {
            return
        }
        throw EpisodeDownloadError.unsupportedContentEncoding
    }
}
