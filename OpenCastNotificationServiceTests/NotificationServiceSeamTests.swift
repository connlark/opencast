import Foundation
import Testing
import UserNotifications

/// The seam trio (guardrails roster): the extension's artwork session is
/// injectable, so expiry, failure, and cancellation behavior are pinned
/// without real network.
@Suite("Notification service session seam")
struct NotificationServiceSeamTests {
    @Test("Non-2xx artwork downloads deliver the notification without an attachment")
    func non2xxArtworkDeliversWithoutAttachment() async throws {
        let host = ArtworkStubProtocol.uniqueHost()
        ArtworkStubProtocol.register(.respond(statusCode: 404, body: Data()), forHost: host)
        let service = NotificationService()
        service.artworkSession = Self.stubbedSession()

        let delivered = DeliveryRecorder()
        service.didReceive(Self.artworkRequest(host: host)) { content in
            delivered.record(content)
        }

        let content = try #require(await delivered.first())
        #expect(content.attachments.isEmpty)
        #expect(delivered.count() == 1)
    }

    @Test("Expiry during a hung download delivers exactly once, without an attachment")
    func expiryDuringHungDownloadDeliversOnce() async throws {
        let host = ArtworkStubProtocol.uniqueHost()
        ArtworkStubProtocol.register(.hang, forHost: host)
        let service = NotificationService()
        service.artworkSession = Self.stubbedSession()

        let delivered = DeliveryRecorder()
        service.didReceive(Self.artworkRequest(host: host)) { content in
            delivered.record(content)
        }
        await ArtworkStubProtocol.requestStarted(forHost: host)

        service.serviceExtensionTimeWillExpire()

        let content = try #require(await delivered.first())
        #expect(content.attachments.isEmpty)
        #expect(delivered.count() == 1)
    }

    @Test("Delivery cancels the in-flight artwork download")
    func deliveryCancelsInFlightDownload() async throws {
        let host = ArtworkStubProtocol.uniqueHost()
        ArtworkStubProtocol.register(.hang, forHost: host)
        let service = NotificationService()
        service.artworkSession = Self.stubbedSession()

        let delivered = DeliveryRecorder()
        service.didReceive(Self.artworkRequest(host: host)) { content in
            delivered.record(content)
        }
        await ArtworkStubProtocol.requestStarted(forHost: host)

        service.serviceExtensionTimeWillExpire()

        _ = try #require(await delivered.first())
        // Post-delivery, the hung download must be torn down — URLProtocol
        // observes the cancellation as stopLoading.
        #expect(await ArtworkStubProtocol.requestStopped(forHost: host))
    }

    @Test("Source gate: the artwork session stays injectable")
    func sourceGateArtworkSessionSeam() throws {
        let serviceSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "OpenCastNotificationService/NotificationService.swift")
        let source = try String(contentsOf: serviceSource, encoding: .utf8)
        #expect(!source.contains("URLSession.shared.downloadTask"))
        #expect(source.contains("var artworkSession"))
        #expect(source.contains("task.delegate = byteCapDelegate"))
    }

    private static func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func artworkRequest(host: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Seam Test"
        content.userInfo = [
            "opencast": [
                "kind": "episode",
                "artwork_url": "https://\(host)/artwork.jpg",
            ],
        ]
        return UNNotificationRequest(
            identifier: "seam-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
    }
}

@Suite("Artwork download byte cap")
struct ArtworkDownloadByteCapDelegateTests {
    @Test("An oversized declared length cancels on the first progress callback")
    func oversizedDeclaredLengthCancelsUpFront() async throws {
        let host = ArtworkStubProtocol.uniqueHost()
        ArtworkStubProtocol.register(
            .stream(declaredLength: 4_000_000, chunkSize: 1_024, chunkCount: 8),
            forHost: host
        )
        let result = await Self.download(host: host, maxArtworkBytes: 1_000_000)

        #expect(result.errorCode == NSURLErrorCancelled)
        #expect(await ArtworkStubProtocol.requestStopped(forHost: host))
    }

    @Test("An unknown-length stream is cancelled once written bytes pass the cap")
    func unknownLengthStreamCancelsMidStream() async throws {
        let host = ArtworkStubProtocol.uniqueHost()
        ArtworkStubProtocol.register(
            .stream(declaredLength: nil, chunkSize: 64 * 1_024, chunkCount: 64),
            forHost: host
        )
        let result = await Self.download(host: host, maxArtworkBytes: 128 * 1_024)

        #expect(result.errorCode == NSURLErrorCancelled)
        #expect(await ArtworkStubProtocol.requestStopped(forHost: host))
    }

    @Test("A download within the cap completes untouched")
    func withinCapDownloadCompletes() async throws {
        let host = ArtworkStubProtocol.uniqueHost()
        ArtworkStubProtocol.register(
            .stream(declaredLength: 2_048, chunkSize: 1_024, chunkCount: 2),
            forHost: host
        )
        let result = await Self.download(host: host, maxArtworkBytes: 1_000_000)

        #expect(result.errorCode == nil)
        #expect(result.receivedByteCount == 2_048)
    }

    private struct DownloadResult {
        let errorCode: Int?
        let receivedByteCount: Int?
    }

    private static func download(host: String, maxArtworkBytes: Int) async -> DownloadResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkStubProtocol.self]
        let session = URLSession(configuration: configuration)
        return await withCheckedContinuation { continuation in
            let delegate = ArtworkDownloadByteCapDelegate(
                maxArtworkBytes: maxArtworkBytes
            ) { temporaryURL, _, error in
                let byteCount = temporaryURL.flatMap {
                    try? Data(contentsOf: $0).count
                }
                continuation.resume(returning: DownloadResult(
                    errorCode: (error as? NSError)?.code,
                    receivedByteCount: byteCount
                ))
            }
            let task = session.downloadTask(
                with: URLRequest(url: URL(string: "https://\(host)/large.jpg")!)
            )
            task.delegate = delegate
            task.resume()
        }
    }
}

/// Records deliveries across the extension's off-main callbacks.
private final class DeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [UNNotificationContent] = []

    func record(_ content: UNNotificationContent) {
        lock.lock()
        contents.append(content)
        lock.unlock()
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return contents.count
    }

    func first() async -> UNNotificationContent? {
        for _ in 0..<1_000 {
            if let first = firstSnapshot() {
                return first
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func firstSnapshot() -> UNNotificationContent? {
        lock.lock()
        defer { lock.unlock() }
        return contents.first
    }
}

/// Host-keyed stub: suites run in parallel, so every test registers its mode
/// under a unique host instead of sharing one global state.
final class ArtworkStubProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable {
        case respond(statusCode: Int, body: Data)
        case hang
        case stream(declaredLength: Int?, chunkSize: Int, chunkCount: Int)
    }

    private struct HostState: Sendable {
        var mode: Mode
        var started = false
        var stopped = false
    }

    private static let states = LockedBox<[String: HostState]>([:])

    static func uniqueHost() -> String {
        "stub-\(UUID().uuidString.lowercased()).example"
    }

    static func register(_ mode: Mode, forHost host: String) {
        states.withLock { $0[host] = HostState(mode: mode) }
    }

    static func requestStarted(forHost host: String) async {
        for _ in 0..<1_000 {
            if states.withLock({ $0[host]?.started == true }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    static func requestStopped(forHost host: String) async -> Bool {
        for _ in 0..<1_000 {
            if states.withLock({ $0[host]?.stopped == true }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private static func host(of request: URLRequest) -> String {
        request.url?.host ?? ""
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let host = Self.host(of: request)
        let mode = Self.states.withLock { states -> Mode in
            states[host]?.started = true
            // Unregistered hosts answer 404 so a stray request fails fast
            // instead of hitting the network or hanging.
            return states[host]?.mode ?? .respond(statusCode: 404, body: Data())
        }
        switch mode {
        case .respond(let statusCode, let body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(body.count)"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .hang:
            break
        case .stream(let declaredLength, let chunkSize, let chunkCount):
            var headers: [String: String] = [:]
            if let declaredLength {
                headers["Content-Length"] = "\(declaredLength)"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Paced off-thread delivery: the session must get time to fire
            // didWriteData between chunks so a byte-cap delegate's cancel can
            // land mid-stream; synchronous delivery would hand over the whole
            // body before any progress callback runs.
            let chunk = Data(repeating: 0xAB, count: chunkSize)
            DispatchQueue.global().async { [weak self] in
                guard let self else {
                    return
                }
                for _ in 0..<chunkCount {
                    if Self.states.withLock({ $0[host]?.stopped == true }) {
                        return
                    }
                    self.client?.urlProtocol(self, didLoad: chunk)
                    usleep(5_000)
                }
                if !Self.states.withLock({ $0[host]?.stopped == true }) {
                    self.client?.urlProtocolDidFinishLoading(self)
                }
            }
        }
    }

    override func stopLoading() {
        let host = Self.host(of: request)
        Self.states.withLock { $0[host]?.stopped = true }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
