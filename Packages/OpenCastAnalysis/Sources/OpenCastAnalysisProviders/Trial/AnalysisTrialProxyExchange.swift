import OpenCastAnalysis

/// Posts one request to the trial service and reads its raw reply. The app
/// implements it: it signs each post with the install's App Attest key (a
/// fresh assertion per post), holds the key's assertion gate until the
/// reply is read, recovers a stale counter or an unknown key once, and caps
/// the body. The trial transport never sees a key, an assertion or a URL.
public protocol AnalysisTrialProxyExchange: Sendable {
    /// - Parameters:
    ///   - path: The route, such as ``TrialProxyAnalysisTransport/analyzePath``.
    ///   - payloadText: The JSON text the post carries as its payload.
    ///   - timeoutSeconds: The whole exchange, signing included, completes
    ///     within it or fails with ``AnalysisHTTPFailure/timeout``.
    ///   - maximumBodyBytes: A longer reply fails with
    ///     ``AnalysisHTTPFailure/oversizedBody``.
    func post(
        path: String,
        payloadText: String,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse
}
