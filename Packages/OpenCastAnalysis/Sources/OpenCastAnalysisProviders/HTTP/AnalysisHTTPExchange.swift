import Foundation
import OpenCastAnalysis

/// The value may be a credential: no textual or reflected form shows it.
public struct AnalysisHTTPHeader: Sendable, Equatable {
    /// Lowercase.
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name.lowercased()
        self.value = value
    }
}

extension AnalysisHTTPHeader: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "\(name): <redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["name": name]) }
}

public struct AnalysisHTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [AnalysisHTTPHeader]
    public var body: Data?

    public init(method: String, url: URL, headers: [AnalysisHTTPHeader], body: Data?) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        let name = name.lowercased()
        return headers.first { $0.name == name }?.value
    }
}

extension AnalysisHTTPRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "\(method) \(url.absoluteString) headers=[\(headers.map(\.name).joined(separator: ","))] bytes=\(body?.count ?? 0)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "method": method,
            "url": url,
            "headerNames": headers.map(\.name),
            "bodyBytes": body?.count ?? 0,
        ])
    }
}

/// The body may echo request content: no textual or reflected form shows it. No raw header is
/// stored, only parsed values.
public struct AnalysisHTTPResponse: Sendable, Equatable {
    public var status: Int
    /// Whole seconds, capped at ``GeminiErrorClassifier/maxRetryAfterSeconds``.
    public var retryAfterSeconds: Int?
    /// A member of ``knownContentTypes`` or `other`.
    public var contentType: String?
    public var body: Data

    public static let knownContentTypes: Set<String> = [
        "application/json", "text/html", "text/plain", "text/event-stream", "application/x-ndjson",
    ]

    public init(status: Int, retryAfter: String? = nil, contentType: String? = nil, body: Data) {
        self.status = status
        retryAfterSeconds = retryAfter.flatMap(GeminiErrorClassifier.retryAfterSeconds)
        self.contentType = contentType.map { header in
            let media = header.split(separator: ";", maxSplits: 1).first.map {
                ProviderJSON.lowercasedASCII($0.trimmingCharacters(in: .whitespaces))
            } ?? ""
            return Self.knownContentTypes.contains(media) ? media : "other"
        }
        self.body = body
    }

    public var retryAfter: String? { retryAfterSeconds.map(String.init) }
}

extension AnalysisHTTPResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "status=\(status) bytes=\(body.count)" }
    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["status": status, "retryAfterSeconds": retryAfterSeconds as Any, "bodyBytes": body.count])
    }
}

public enum AnalysisHTTPFailure: Error, Sendable, Hashable {
    case timeout
    case network
    case oversizedBody
}

public protocol AnalysisHTTPClient: Sendable {
    /// `timeoutSeconds` bounds the whole exchange, body read included.
    func send(
        _ request: AnalysisHTTPRequest,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse
}
