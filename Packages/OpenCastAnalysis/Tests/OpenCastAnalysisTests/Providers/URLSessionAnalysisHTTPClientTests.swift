import Foundation
@testable import OpenCastAnalysisProviders
import Synchronization
import Testing

/// Serves canned exchanges by host, so tests on different hosts never meet.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior: Sendable {
        case respond(status: Int, headers: [String: String], body: Data)
        case fail(URLError.Code)
        case redirect(to: URL)
        case hang
    }

    static let behaviors = Mutex<[String: Behavior]>([:])
    static let seen = Mutex<[String: (headers: [String: String], body: Data)]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let headers = request.allHTTPHeaderFields ?? [:]
        Self.seen.withLock { $0[host] = (headers, body) }
        switch Self.behaviors.withLock({ $0[host] }) {
        case .respond(let status, let headers, let body)?:
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code)?:
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .redirect(let target)?:
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .hang?, nil:
            break
        }
    }

    override func stopLoading() {}
}

@Suite("URLSession provider client")
struct URLSessionAnalysisHTTPClientTests {
    let client = URLSessionAnalysisHTTPClient(session: URLSessionAnalysisHTTPClient.makeSession(protocolClasses: [StubURLProtocol.self]))

    func request(_ host: String, body: String = "{\"a\":1}") -> AnalysisHTTPRequest {
        AnalysisHTTPRequest(
            method: "POST",
            url: URL(string: "https://\(host)/v1/x")!,
            headers: [AnalysisHTTPHeader("content-type", "application/json"), AnalysisHTTPHeader("x-goog-api-key", "k")],
            body: Data(body.utf8)
        )
    }

    func result(_ request: AnalysisHTTPRequest, timeout: Double = 60, maximum: Int = 1_000) async -> Result<AnalysisHTTPResponse, AnalysisHTTPFailure> {
        do {
            return .success(try await client.send(request, timeoutSeconds: timeout, maximumBodyBytes: maximum))
        } catch {
            return .failure(error)
        }
    }

    @Test("Status, Retry-After and body come back; headers and body went out")
    func roundTrip() async throws {
        StubURLProtocol.behaviors.withLock { $0["round.test"] = .respond(status: 429, headers: ["Retry-After": "9"], body: Data("busy".utf8)) }
        let response = try await result(request("round.test")).get()
        #expect(response == AnalysisHTTPResponse(status: 429, retryAfter: "9", body: Data("busy".utf8)))
        let seen = try #require(StubURLProtocol.seen.withLock { $0["round.test"] })
        #expect(seen.body == Data("{\"a\":1}".utf8))
        #expect(seen.headers["x-goog-api-key"] == "k")
        #expect(seen.headers["Content-Type"] == "application/json" || seen.headers["content-type"] == "application/json")
    }

    @Test("A body past the cap is oversized")
    func oversized() async {
        StubURLProtocol.behaviors.withLock { $0["big.test"] = .respond(status: 200, headers: [:], body: Data(count: 2_000)) }
        #expect(await result(request("big.test"), maximum: 1_000) == .failure(.oversizedBody))
        StubURLProtocol.behaviors.withLock { $0["exact.test"] = .respond(status: 200, headers: [:], body: Data(count: 1_000)) }
        #expect((try? await result(request("exact.test"), maximum: 1_000).get().body.count) == 1_000)
    }

    @Test("A provider that never answers times out at the deadline")
    func deadline() async {
        StubURLProtocol.behaviors.withLock { $0["hang.test"] = .hang }
        let started = ContinuousClock.now
        #expect(await result(request("hang.test"), timeout: 0.3) == .failure(.timeout))
        // The stub never answers: a client without the deadline would never
        // return, so the bound only has to be finite, not a guess at load.
        #expect(started.duration(to: .now) < .seconds(300))
        #expect(await result(request("hang.test"), timeout: 0) == .failure(.timeout))
    }

    @Test("URLError timedOut is a timeout; any other URLError is a network failure")
    func urlErrors() async {
        StubURLProtocol.behaviors.withLock {
            $0["slow.test"] = .fail(.timedOut)
            $0["offline.test"] = .fail(.notConnectedToInternet)
            $0["tls.test"] = .fail(.secureConnectionFailed)
        }
        #expect(await result(request("slow.test")) == .failure(.timeout))
        #expect(await result(request("offline.test")) == .failure(.network))
        #expect(await result(request("tls.test")) == .failure(.network))
    }

    @Test("A redirect is never followed, so the key's header never reaches another host")
    func redirectsRefused() async {
        StubURLProtocol.behaviors.withLock {
            $0["origin.test"] = .redirect(to: URL(string: "https://elsewhere.test/collect")!)
            $0["elsewhere.test"] = .respond(status: 200, headers: [:], body: Data("{}".utf8))
        }
        let outcome = await result(request("origin.test"))
        #expect(StubURLProtocol.seen.withLock { $0["elsewhere.test"] } == nil)
        if case .success(let response) = outcome {
            #expect(response.status == 302)
        }
    }

    @Test("The session keeps nothing between calls")
    func ephemeral() {
        let configuration = URLSessionAnalysisHTTPClient.makeSession().configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
    }
}

extension URLSessionAnalysisHTTPClientTests {
    @Test("A huge timeout neither traps nor changes the answer")
    func hugeTimeout() async {
        StubURLProtocol.behaviors.withLock { $0["huge.test"] = .respond(status: 200, headers: [:], body: Data("{}".utf8)) }
        #expect((try? await result(request("huge.test"), timeout: 1e300).get().status) == 200)
    }
}
