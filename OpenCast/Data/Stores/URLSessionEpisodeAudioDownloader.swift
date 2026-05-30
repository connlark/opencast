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
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        if sourceURL.isFileURL {
            try await copyLocalFile(from: sourceURL, to: temporaryURL, progress: progress)
            return
        }

        var request = URLRequest(url: sourceURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.bytes(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw EpisodeDownloadError.invalidHTTPStatus(httpResponse.statusCode)
        }

        let expectedBytes = response.expectedContentLength >= 0
            ? response.expectedContentLength
            : nil
        try await write(bytes: bytes, expectedBytes: expectedBytes, to: temporaryURL, progress: progress)
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
        to temporaryURL: URL,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: temporaryURL)
        defer {
            try? fileHandle.close()
        }

        var receivedBytes: Int64 = 0
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
        await progress(receivedBytes, expectedBytes)
    }
}
