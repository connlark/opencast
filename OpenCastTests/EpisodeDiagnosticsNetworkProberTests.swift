import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode diagnostics network prober", .serialized)
struct EpisodeDiagnosticsNetworkProberTests {
    @Test("Probe sends exactly one HEAD request and parses identity headers")
    func probeSendsSingleHEADAndParsesHeaders() async throws {
        DiagnosticsProbeURLProtocol.configure(stubs: [
            DiagnosticsProbeURLProtocol.Stub(
                statusCode: 200,
                headers: [
                    "Content-Type": "audio/mpeg",
                    "Content-Length": "52428800",
                    "Accept-Ranges": "bytes",
                    "ETag": "\"abc123\"",
                    "Last-Modified": "Wed, 27 Aug 2026 08:00:00 GMT",
                ]
            ),
        ])
        let prober = makeProber()

        let probe = await prober.headProbe(of: URL(string: "https://example.com/episode.mp3")!)

        let requests = DiagnosticsProbeURLProtocol.requests
        #expect(requests.count == 1)
        #expect(requests.first?.httpMethod == "HEAD")
        #expect(requests.first?.timeoutInterval == EpisodeDiagnosticsNetworkProber.probeTimeout)
        #expect(probe.requestedURL == "https://example.com/episode.mp3")
        #expect(probe.redirectURLs.isEmpty)
        #expect(probe.finalURL == "https://example.com/episode.mp3")
        #expect(probe.statusCode == 200)
        #expect(probe.mimeType == "audio/mpeg")
        #expect(probe.contentLength == 52_428_800)
        #expect(probe.acceptRanges == "bytes")
        #expect(probe.entityTag == "\"abc123\"")
        #expect(probe.lastModified == "Wed, 27 Aug 2026 08:00:00 GMT")
        #expect(probe.errorDescription == nil)
    }

    @Test("Redirects are recorded and the follow-up request stays HEAD")
    func redirectsAreRecordedAndStayHEAD() async throws {
        DiagnosticsProbeURLProtocol.configure(stubs: [
            DiagnosticsProbeURLProtocol.Stub(
                statusCode: 302,
                headers: ["Location": "https://cdn.example.com/episode-final.mp3"]
            ),
            DiagnosticsProbeURLProtocol.Stub(
                statusCode: 200,
                headers: ["Content-Type": "audio/mpeg"]
            ),
        ])
        let prober = makeProber()

        let probe = await prober.headProbe(of: URL(string: "https://example.com/episode.mp3")!)

        let requests = DiagnosticsProbeURLProtocol.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "HEAD" })
        #expect(probe.redirectURLs == ["https://cdn.example.com/episode-final.mp3"])
        #expect(probe.finalURL == "https://cdn.example.com/episode-final.mp3")
        #expect(probe.statusCode == 200)
    }

    @Test("A transport error surfaces without any retry or body fallback")
    func transportErrorSurfacesWithoutRetry() async throws {
        DiagnosticsProbeURLProtocol.configure(stubs: [])
        let prober = makeProber()

        let probe = await prober.headProbe(of: URL(string: "https://example.com/missing.xml")!)

        #expect(DiagnosticsProbeURLProtocol.requests.count == 1)
        #expect(probe.statusCode == nil)
        #expect(probe.errorDescription != nil)
    }

    @Test("Cancelling the probing task ends a hanging probe promptly")
    func cancellationEndsHangingProbe() async throws {
        DiagnosticsProbeURLProtocol.configure(
            stubs: [DiagnosticsProbeURLProtocol.Stub(statusCode: 200, headers: [:])],
            finishesResponses: false
        )
        let prober = makeProber()

        let probeTask = Task {
            await prober.headProbe(of: URL(string: "https://example.com/hang.mp3")!)
        }
        try await Task.sleep(for: .milliseconds(150))
        probeTask.cancel()
        let probe = await probeTask.value

        #expect(probe.statusCode == nil)
        #expect(probe.errorDescription != nil)
    }

    private func makeProber() -> EpisodeDiagnosticsNetworkProber {
        let configuration = EpisodeDiagnosticsNetworkProber.defaultConfiguration()
        configuration.protocolClasses = [DiagnosticsProbeURLProtocol.self]
        return EpisodeDiagnosticsNetworkProber(configuration: configuration)
    }
}

/// Redirect-capable stub: a 3xx stub with a Location header drives the
/// session's real redirect path so the prober's delegate is exercised.
private nonisolated final class DiagnosticsProbeURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var statusCode: Int
        var headers: [String: String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var finishesResponses = true

    static var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    static func configure(stubs: [Stub], finishesResponses: Bool = true) {
        lock.withLock {
            self.stubs = stubs
            self.finishesResponses = finishesResponses
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
        let fixture = Self.lock.withLock { () -> (Stub, Bool)? in
            Self.recordedRequests.append(request)
            guard !Self.stubs.isEmpty else {
                return nil
            }
            return (Self.stubs.removeFirst(), Self.finishesResponses)
        }

        guard let (stub, finishesResponse) = fixture,
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

        if (300...399).contains(stub.statusCode),
           let location = stub.headers["Location"],
           let redirectURL = URL(string: location, relativeTo: url) {
            var redirectRequest = request
            redirectRequest.url = redirectURL
            client?.urlProtocol(self, wasRedirectedTo: redirectRequest, redirectResponse: response)
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if finishesResponse {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
    }
}
