import CryptoKit
import Foundation

public struct OpenCastHTTPFileResult: Sendable {
    public let fileURL: URL
    public let response: OpenCastHTTPResponse
    public let decodedByteCount: Int
    public let bodyHash: String?
    public let incompleteReason: FeedIncompleteReason?
    private let workspace: FeedWorkspace

    init(fileURL: URL, response: OpenCastHTTPResponse, decodedByteCount: Int, bodyHash: String?,
         incompleteReason: FeedIncompleteReason?, workspace: FeedWorkspace) {
        self.fileURL = fileURL
        self.response = response
        self.decodedByteCount = decodedByteCount
        self.bodyHash = bodyHash
        self.incompleteReason = incompleteReason
        self.workspace = workspace
    }
}

extension SHA256.Digest {
    var feedHex: String { map { String(format: "%02x", $0) }.joined() }
}

public extension OpenCastHTTPClient {
    /// Compatibility for injected/materializing clients. URLSession's
    /// production implementation writes decoded chunks directly to disk.
    func feedFile(for request: URLRequest, maximumBodyByteCount: Int) async throws -> OpenCastHTTPFileResult {
        let result = try await data(for: request)
        try Task.checkCancellation()
        let workspace = try FeedWorkspace()
        let url = workspace.file("feed.xml")
        let successful = result.response.statusCode.map { (200..<300).contains($0) } == true
        let data = successful ? result.data.prefix(maximumBodyByteCount) : Data()
        try data.write(to: url)
        let partial = successful && result.data.count > maximumBodyByteCount
        return OpenCastHTTPFileResult(fileURL: url, response: result.response, decodedByteCount: data.count,
            bodyHash: partial ? nil : SHA256.hash(data: data).feedHex,
            incompleteReason: partial ? .decodedByteLimit : nil, workspace: workspace)
    }
}
