import Foundation
import OpenCastCore

/// Issues one HEAD request per probe: no retries, no GET or Range fallback,
/// and an eight-second ceiling so a slow host can't pin the sheet. Redirects
/// are followed but forced to stay HEAD.
nonisolated final class EpisodeDiagnosticsNetworkProber: EpisodeDiagnosticsNetworkProbing {
    static let probeTimeout: TimeInterval = 8

    private let session: URLSession

    init(configuration: URLSessionConfiguration = EpisodeDiagnosticsNetworkProber.defaultConfiguration()) {
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = probeTimeout
        configuration.timeoutIntervalForResource = probeTimeout
        configuration.httpAdditionalHeaders = ["User-Agent": OpenCastURLSessionFactory.userAgent]
        configuration.urlCache = nil
        return configuration
    }

    func headProbe(of url: URL) async -> EpisodeDiagnosticsHeadProbe {
        var probe = EpisodeDiagnosticsHeadProbe(requestedURL: url.absoluteString)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = Self.probeTimeout

        let redirectRecorder = RedirectRecorder()
        do {
            let (_, response) = try await session.data(for: request, delegate: redirectRecorder)
            probe.redirectURLs = redirectRecorder.redirectURLStrings
            if let httpResponse = response as? HTTPURLResponse {
                probe.finalURL = httpResponse.url?.absoluteString
                probe.statusCode = httpResponse.statusCode
                probe.mimeType = httpResponse.mimeType
                probe.contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length")
                    .flatMap(Int64.init)
                probe.acceptRanges = httpResponse.value(forHTTPHeaderField: "Accept-Ranges")
                probe.entityTag = httpResponse.value(forHTTPHeaderField: "ETag")
                probe.lastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified")
            }
        } catch {
            probe.redirectURLs = redirectRecorder.redirectURLStrings
            probe.errorDescription = error.localizedDescription
        }
        return probe
    }
}

/// Session delegate callbacks arrive on the session's queue, so the recorded
/// chain sits behind a lock.
private nonisolated final class RedirectRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLStrings: [String] = []

    var redirectURLStrings: [String] {
        lock.withLock { recordedURLStrings }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if let urlString = request.url?.absoluteString {
            lock.withLock { recordedURLStrings.append(urlString) }
        }
        // Some hosts answer 301/302 expecting the follow-up to become GET;
        // a probe must never fetch media, so the method is pinned.
        var headRequest = request
        headRequest.httpMethod = "HEAD"
        completionHandler(headRequest)
    }
}
