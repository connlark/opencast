import Foundation
@preconcurrency import Network

// Mutable request and connection state is gated by `queue`; URLs are finalized during init before publication.
final class HTTPFixtureServer: @unchecked Sendable {
    private static let queueContext = DispatchSpecificKey<Void>()

    private(set) var url: URL
    private(set) var baseURL: URL

    private let scenario: HTTPFixtureServerScenario
    private let listener: NWListener
    private let queue = DispatchQueue(label: "OpenCastPlaybackTests.HTTPFixtureServer")
    private var receivedRequests: [HTTPFixtureRequest] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    var recordedRequests: [HTTPFixtureRequest] {
        queue.sync {
            receivedRequests
        }
    }

    convenience init(
        data: Data,
        fileName: String,
        contentType: String,
        acceptsRanges: Bool = true,
        etag: String? = #""opencast-fixture""#,
        lastModified: String? = nil
    ) throws {
        try self.init(scenario: HTTPFixtureServerScenario(
            data: data,
            fileName: fileName,
            contentType: contentType,
            rangeBehavior: acceptsRanges ? .normal : .none,
            validatorBehavior: .stable(etag: etag, lastModified: lastModified)
        ))
    }

    init(scenario: HTTPFixtureServerScenario) throws {
        self.scenario = scenario
        url = URL(fileURLWithPath: "/")
        baseURL = URL(fileURLWithPath: "/")
        listener = try NWListener(using: .tcp, on: .any)
        queue.setSpecific(key: Self.queueContext, value: ())

        let readySemaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                readySemaphore.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard readySemaphore.wait(timeout: .now() + 5) == .success,
              let port = listener.port?.rawValue,
              let baseURL = URL(string: "http://127.0.0.1:\(port)"),
              let url = URL(string: scenario.primaryPath, relativeTo: baseURL)?.absoluteURL
        else {
            listener.cancel()
            throw Error.failedToStart
        }

        self.baseURL = baseURL
        self.url = url
    }

    func stop() {
        if DispatchQueue.getSpecific(key: Self.queueContext) != nil {
            cancelServer()
            return
        }

        queue.sync {
            cancelServer()
        }
    }

    private func cancelServer() {
        listener.cancel()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func handle(_ connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        connections[connectionID] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed,
                 .cancelled:
                self?.removeConnection(connectionID)
            default:
                break
            }
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] requestData, _, _, _ in
            guard let self, let requestData else {
                connection.cancel()
                return
            }

            self.send(self.response(for: requestData), on: connection)
        }
    }

    private func response(for requestData: Data) -> Response {
        let rawRequest = String(decoding: requestData, as: UTF8.self)
        let request = HTTPFixtureRequest(rawRequest)
        receivedRequests.append(request)
        let requestNumber = receivedRequests.count

        if let location = redirectLocation(for: request, requestNumber: requestNumber) {
            return redirectResponse(location: location)
        }

        guard serves(request.path) else {
            return response(status: "404 Not Found", body: Data("Not Found".utf8), request: request)
        }

        return response(
            status: status(for: request),
            body: body(for: request),
            request: request,
            contentRange: contentRange(for: request),
            requestNumber: requestNumber
        )
    }

    private func status(for request: HTTPFixtureRequest) -> String {
        let hasRange = request.byteRange != nil
        switch scenario.rangeBehavior {
        case .normal:
            return hasRange ? "206 Partial Content" : "200 OK"
        case .none,
             .ignored:
            return "200 OK"
        case .partialWithoutContentRange,
             .malformedContentRange,
             .unknownTotal,
             .mismatchedContentRange:
            return hasRange ? "206 Partial Content" : "200 OK"
        case .rangeNotSatisfiable:
            return hasRange ? "416 Range Not Satisfiable" : "200 OK"
        }
    }

    private func body(for request: HTTPFixtureRequest) -> Data {
        let fullBody = scenario.data
        guard let requestedRange = request.byteRange?.resolved(contentLength: fullBody.count) else {
            return fullBody
        }

        switch scenario.rangeBehavior {
        case .normal,
             .partialWithoutContentRange,
             .malformedContentRange,
             .unknownTotal,
             .mismatchedContentRange:
            return fullBody.subdata(in: requestedRange)
        case .none,
             .ignored:
            return fullBody
        case .rangeNotSatisfiable:
            return Data()
        }
    }

    private func contentRange(for request: HTTPFixtureRequest) -> String? {
        guard let requestedRange = request.byteRange?.resolved(contentLength: scenario.data.count) else {
            return nil
        }

        let lowerBound = requestedRange.lowerBound
        let upperBound = requestedRange.upperBound - 1
        switch scenario.rangeBehavior {
        case .normal:
            return "bytes \(lowerBound)-\(upperBound)/\(scenario.data.count)"
        case .rangeNotSatisfiable:
            return "bytes */\(scenario.data.count)"
        case .malformedContentRange(let value):
            return value
        case .unknownTotal:
            return "bytes \(lowerBound)-\(upperBound)/*"
        case .mismatchedContentRange:
            return "bytes \(lowerBound + 1)-\(upperBound + 1)/\(scenario.data.count)"
        case .none,
             .ignored,
             .partialWithoutContentRange:
            return nil
        }
    }

    private func response(
        status: String,
        body: Data,
        request: HTTPFixtureRequest,
        contentRange: String? = nil,
        requestNumber: Int = 1
    ) -> Response {
        var headerLines = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(scenario.contentType)",
            "Content-Length: \(declaredContentLength(for: body))",
            "Cache-Control: no-store",
            "Connection: close",
            "Accept-Ranges: \(scenario.rangeBehavior.advertisesRanges ? "bytes" : "none")"
        ]

        if let contentRange {
            headerLines.append("Content-Range: \(contentRange)")
        }
        headerLines.append(contentsOf: validatorHeaders(for: requestNumber))

        return Response(
            headerData: headerData(from: headerLines),
            body: request.method.uppercased() == "HEAD" ? Data() : body,
            bodyBehavior: scenario.bodyBehavior
        )
    }

    private func redirectResponse(location: String) -> Response {
        let headerLines = [
            "HTTP/1.1 302 Found",
            "Location: \(location)",
            "Content-Length: 0",
            "Cache-Control: no-store",
            "Connection: close"
        ]
        return Response(
            headerData: headerData(from: headerLines),
            body: Data(),
            bodyBehavior: .immediate
        )
    }

    private func headerData(from headerLines: [String]) -> Data {
        var data = Data(headerLines.joined(separator: "\r\n").utf8)
        data.append(Data("\r\n\r\n".utf8))
        return data
    }

    private func declaredContentLength(for body: Data) -> Int {
        switch scenario.bodyBehavior {
        case .wrongContentLength(let delta):
            max(body.count + delta, 0)
        case .immediate,
             .slow,
             .earlyClose:
            body.count
        }
    }

    private func validatorHeaders(for requestNumber: Int) -> [String] {
        switch scenario.validatorBehavior {
        case .stable(let etag, let lastModified):
            return headers(etag: etag, lastModified: lastModified)
        case .missing:
            return []
        case .changing(let etags, let lastModifieds):
            let index = requestNumber - 1
            let etag = value(in: etags, at: index)
            let lastModified = value(in: lastModifieds, at: index).flatMap { $0 }
            return headers(etag: etag, lastModified: lastModified)
        }
    }

    private func headers(etag: String?, lastModified: String?) -> [String] {
        var headers: [String] = []
        if let etag {
            headers.append("ETag: \(etag)")
        }
        if let lastModified {
            headers.append("Last-Modified: \(lastModified)")
        }
        return headers
    }

    private func value<Value>(in values: [Value], at index: Int) -> Value? {
        guard !values.isEmpty else {
            return nil
        }
        return values[min(max(index, 0), values.count - 1)]
    }

    private func redirectLocation(for request: HTTPFixtureRequest, requestNumber: Int) -> String? {
        guard strippedQuery(from: request.path) == scenario.primaryPath else {
            return nil
        }

        switch scenario.redirectBehavior {
        case .none:
            return nil
        case .stable(let path):
            return scenario.normalizedRedirectPath(path)
        case .unstable(let prefix):
            return "\(scenario.normalizedRedirectPath(prefix))\(requestNumber).mp3"
        }
    }

    private func serves(_ requestPath: String) -> Bool {
        let requestPath = strippedQuery(from: requestPath)
        if requestPath == scenario.primaryPath {
            return true
        }

        switch scenario.redirectBehavior {
        case .none:
            return false
        case .stable(let path):
            return requestPath == scenario.normalizedRedirectPath(path)
        case .unstable(let prefix):
            return requestPath.hasPrefix(scenario.normalizedRedirectPath(prefix))
        }
    }

    private func strippedQuery(from path: String) -> String {
        path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
    }

    private func removeConnection(_ connectionID: ObjectIdentifier) {
        queue.async {
            self.connections[connectionID] = nil
        }
    }

    private func isActive(_ connection: NWConnection) -> Bool {
        connections[ObjectIdentifier(connection)] != nil
    }

    private func send(_ response: Response, on connection: NWConnection) {
        switch response.bodyBehavior {
        case .immediate,
             .wrongContentLength:
            var data = response.headerData
            data.append(response.body)
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        case .earlyClose(let afterBytes):
            var data = response.headerData
            data.append(response.body.prefix(max(afterBytes, 0)))
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        case .slow(let chunkSize, let interval):
            connection.send(content: response.headerData, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil, self.isActive(connection) else {
                    connection.cancel()
                    return
                }
                self.sendBodyChunks(
                    response.body,
                    chunkSize: max(chunkSize, 1),
                    interval: interval,
                    offset: 0,
                    on: connection
                )
            })
        }
    }

    private func sendBodyChunks(
        _ body: Data,
        chunkSize: Int,
        interval: TimeInterval,
        offset: Int,
        on connection: NWConnection
    ) {
        guard isActive(connection) else {
            return
        }
        guard offset < body.count else {
            connection.cancel()
            return
        }

        let end = min(offset + chunkSize, body.count)
        connection.send(content: body.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil, self.isActive(connection) else {
                connection.cancel()
                return
            }
            self.queue.asyncAfter(deadline: .now() + max(interval, 0)) { [weak self] in
                self?.sendBodyChunks(
                    body,
                    chunkSize: chunkSize,
                    interval: interval,
                    offset: end,
                    on: connection
                )
            }
        })
    }

    private struct Response {
        var headerData: Data
        var body: Data
        var bodyBehavior: HTTPFixtureServerScenario.BodyBehavior
    }

    enum Error: Swift.Error {
        case failedToStart
    }
}
