import Foundation
import OpenCastAnalysisProviders

/// Reads one trial service reply whole, capped, and keeps only the parsed
/// headers the classifiers read.
nonisolated enum TrialProxyHTTPReading {
    static func read(
        _ request: URLRequest,
        session: URLSession,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw .timeout
        } catch {
            throw .network
        }
        return try reply(data: data, response: response, maximumBodyBytes: maximumBodyBytes)
    }

    static func reply(data: Data, response: URLResponse, maximumBodyBytes: Int) throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        guard let http = response as? HTTPURLResponse else { throw .network }
        guard data.count <= maximumBodyBytes else { throw .oversizedBody }
        return AnalysisHTTPResponse(
            status: http.statusCode,
            retryAfter: http.value(forHTTPHeaderField: "retry-after"),
            contentType: http.value(forHTTPHeaderField: "content-type"),
            body: data
        )
    }
}
