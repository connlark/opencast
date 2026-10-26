import Foundation
import OpenCastAnalysis

/// Downloads one policy document. Implementations stop reading past
/// `maximumBytes` and throw `AnalysisPolicyRejection` for a bad status.
public protocol AnalysisPolicyFetching: Sendable {
    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data
}

/// Where the policy is served: the model gateway that also serves the
/// transcription model manifest. The current signature is mutable and names
/// one version; each version's bundle sits at its own immutable URL.
public struct AnalysisPolicyEndpoint: Sendable, Equatable {
    public var baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public var signatureURL: URL {
        baseURL.appending(path: "v1/policies/analysis.sig")
    }

    public func bundleURL(version: Int) -> URL {
        baseURL.appending(path: "v1/policies/analysis/\(version).json")
    }
}

public struct URLSessionAnalysisPolicyFetcher: AnalysisPolicyFetching {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (bytes, response) = try await session.bytes(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw AnalysisPolicyRejection.fetchFailed("http_\((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw AnalysisPolicyRejection.tooLarge(bytes: Int(response.expectedContentLength))
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumBytes {
                throw AnalysisPolicyRejection.tooLarge(bytes: data.count)
            }
        }
        return data
    }
}
