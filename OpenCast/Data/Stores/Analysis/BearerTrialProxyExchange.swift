#if DEBUG
import Foundation
import OpenCastAnalysisProviders

/// Debug builds on a simulator, which cannot attest: posts the payload as
/// the body with the service's operator bearer.
nonisolated struct BearerTrialProxyExchange: AnalysisTrialProxyExchange {
    let baseURL: URL
    let clientToken: String
    var session: URLSession = .shared

    func post(
        path: String,
        payloadText: String,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = max(timeoutSeconds, 1)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(clientToken)", forHTTPHeaderField: "authorization")
        request.httpBody = Data(payloadText.utf8)
        return try await TrialProxyHTTPReading.read(request, session: session, maximumBodyBytes: maximumBodyBytes)
    }
}
#endif
