import Foundation

/// Provider exchanges over a plain `URLSession` that keeps nothing: no
/// response cache, no cookies, no credential storage, and never follows a
/// redirect (a redirect would carry the key's header to another host; the
/// 3xx answer comes back as is). Each request carries its timeout as the
/// task's idle timeout, and the whole exchange races an overall deadline of
/// the same length.
public struct URLSessionAnalysisHTTPClient: AnalysisHTTPClient {
    public let session: URLSession

    public init(session: URLSession = URLSessionAnalysisHTTPClient.makeSession()) {
        self.session = session
    }

    /// An ephemeral session for provider calls. `protocolClasses` lets tests
    /// serve canned exchanges.
    public static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(configuration: configuration)
    }

    public func send(
        _ request: AnalysisHTTPRequest,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        let limit = AnalysisProviderLimits.waitSeconds(timeoutSeconds)
        guard limit > 0 else { throw .timeout }
        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: limit
        )
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false
        for header in request.headers {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
        }
        urlRequest.httpBody = request.body
        let session = session
        let prepared = urlRequest
        do {
            return try await withThrowingTaskGroup(of: AnalysisHTTPResponse?.self) { group in
                group.addTask {
                    try await Self.exchange(session, prepared, maximumBodyBytes: maximumBodyBytes)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(limit))
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let response = first else {
                    throw AnalysisHTTPFailure.timeout
                }
                return response
            }
        } catch let failure as AnalysisHTTPFailure {
            throw failure
        } catch let error as URLError where error.code == .timedOut {
            throw .timeout
        } catch {
            throw .network
        }
    }

    private static func exchange(
        _ session: URLSession,
        _ request: URLRequest,
        maximumBodyBytes: Int
    ) async throws -> AnalysisHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectRefusal())
        guard let http = response as? HTTPURLResponse else { throw AnalysisHTTPFailure.network }
        if http.expectedContentLength > Int64(maximumBodyBytes) {
            throw AnalysisHTTPFailure.oversizedBody
        }
        var body = Data()
        for try await byte in bytes {
            guard body.count < maximumBodyBytes else { throw AnalysisHTTPFailure.oversizedBody }
            body.append(byte)
        }
        return AnalysisHTTPResponse(
            status: http.statusCode,
            retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            body: body
        )
    }
}

/// Refuses every redirect, so a request only ever reaches the URL it was
/// built for. (The completion-handler form: Swift 6.4's SILGen crashes on
/// the async form of this delegate method in this package's settings.)
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
