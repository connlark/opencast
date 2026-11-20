import OpenCastAnalysis

/// Implementations sign each post with a fresh App Attest assertion and hold the key's assertion
/// gate until the reply is read. The trial transport never sees a key, an assertion or a URL.
public protocol AnalysisTrialProxyExchange: Sendable {
    /// `timeoutSeconds` bounds the whole exchange, signing included.
    func post(
        path: String,
        payloadText: String,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse
}
