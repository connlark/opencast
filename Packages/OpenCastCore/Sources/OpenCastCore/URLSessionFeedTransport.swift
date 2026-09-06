import CryptoKit
import Foundation

extension URLSessionOpenCastHTTPClient {
    @concurrent
    public func feedFile(for request: URLRequest, maximumBodyByteCount: Int) async throws -> OpenCastHTTPFileResult {
        let workspace = try FeedWorkspace()
        let fileURL = workspace.file("feed.xml")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: fileURL)
        defer { try? output.close() }
        let (bytes, rawResponse) = try await feedSession.bytes(for: request)
        let response = OpenCastHTTPResponse(rawResponse)
        // Status always wins over a server's error-page Content-Length.
        guard let status = response.statusCode, (200..<300).contains(status) else {
            bytes.task.cancel()
            return OpenCastHTTPFileResult(fileURL: fileURL, response: response, decodedByteCount: 0,
                bodyHash: nil, incompleteReason: nil, workspace: workspace)
        }
        return try await withTaskCancellationHandler {
            var chunk = Data()
            chunk.reserveCapacity(FeedResourcePolicy.chunkBytes)
            var count = 0
            var hash = SHA256()
            var issue: FeedIncompleteReason?
            // File errors must throw, never masquerade as recoverable network
            // truncation. Only the iterator's own error becomes a partial feed.
            var iterator = bytes.makeAsyncIterator()
            while true {
                let next: UInt8?
                do { next = try await iterator.next() }
                catch {
                    try Task.checkCancellation()
                    if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    issue = .interruptedTransfer(error.localizedDescription)
                    break
                }
                guard let next else { break }
                if count + chunk.count == maximumBodyByteCount {
                    issue = .decodedByteLimit
                    bytes.task.cancel()
                    break
                }
                chunk.append(next)
                if chunk.count == FeedResourcePolicy.chunkBytes {
                    try Task.checkCancellation()
                    do { try output.write(contentsOf: chunk) }
                    catch { bytes.task.cancel(); throw error }
                    hash.update(data: chunk)
                    count += chunk.count
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
            hash.update(data: chunk)
            count += chunk.count
            return OpenCastHTTPFileResult(fileURL: fileURL, response: response, decodedByteCount: count,
                bodyHash: issue == nil ? hash.finalize().feedHex : nil, incompleteReason: issue, workspace: workspace)
        } onCancel: {
            bytes.task.cancel()
        }
    }
}
