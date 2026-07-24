import Foundation

nonisolated final class EpisodeDownloadTestURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Stub = (statusCode: Int, headers: [String: String], body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var finishesResponses = true
    nonisolated(unsafe) private static var deliveryChunkByteCount: Int?

    static var requests: [URLRequest] {
        lock.withLock {
            recordedRequests
        }
    }

    static func configure(
        stubs: [Stub],
        finishesResponses: Bool = true,
        deliveryChunkByteCount: Int? = nil
    ) {
        lock.withLock {
            self.stubs = stubs
            self.finishesResponses = finishesResponses
            self.deliveryChunkByteCount = deliveryChunkByteCount
            recordedRequests.removeAll()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let responseFixture = Self.lock.withLock { () -> (Stub, Bool, Int?)? in
            Self.recordedRequests.append(request)
            guard Self.stubs.isEmpty == false else {
                return nil
            }
            return (
                Self.stubs.removeFirst(),
                Self.finishesResponses,
                Self.deliveryChunkByteCount
            )
        }

        guard let (stub, finishesResponse, deliveryChunkByteCount) = responseFixture,
              let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: nil,
                headerFields: stub.headers
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let deliveryChunkByteCount, deliveryChunkByteCount > 0 {
            for lowerBound in stride(from: 0, to: stub.body.count, by: deliveryChunkByteCount) {
                let upperBound = min(lowerBound + deliveryChunkByteCount, stub.body.count)
                client?.urlProtocol(self, didLoad: stub.body.subdata(in: lowerBound..<upperBound))
            }
        } else {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        if finishesResponse {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
    }
}
