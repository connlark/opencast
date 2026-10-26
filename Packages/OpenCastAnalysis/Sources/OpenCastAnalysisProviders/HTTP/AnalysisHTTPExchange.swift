import Foundation
import OpenCastAnalysis

/// One header of a provider request. Its value may be a credential, so no
/// textual or reflected form of a header ever shows the value.
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

/// One request a provider transport sends.
public struct AnalysisHTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    /// In send order.
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

/// A provider's answer to one request, read whole. The body may echo request
/// content, so no textual or reflected form shows it. The `Retry-After` and
/// `Content-Type` headers are kept only as parsed values; no raw header is
/// stored.
public struct AnalysisHTTPResponse: Sendable, Equatable {
    public var status: Int
    /// `Retry-After` as whole seconds, capped at
    /// ``GeminiErrorClassifier/maxRetryAfterSeconds``, the services' reading
    /// of it; `nil` when absent or unreadable.
    public var retryAfterSeconds: Int?
    /// The media type from `Content-Type`, from a closed set
    /// (``knownContentTypes``) or `other`; `nil` when absent.
    public var contentType: String?
    public var body: Data

    public static let knownContentTypes: Set<String> = [
        "application/json", "text/html", "text/plain", "text/event-stream", "application/x-ndjson",
    ]

    /// - Parameters:
    ///   - retryAfter: The `Retry-After` header as sent; only its parsed,
    ///     capped value is kept.
    ///   - contentType: The `Content-Type` header as sent; only its media
    ///     type, read into the closed set, is kept.
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

    /// The kept delay in header form, for the classifiers, which read
    /// whole seconds.
    public var retryAfter: String? { retryAfterSeconds.map(String.init) }
}

extension AnalysisHTTPResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "status=\(status) bytes=\(body.count)" }
    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["status": status, "retryAfterSeconds": retryAfterSeconds as Any, "bodyBytes": body.count])
    }
}

/// Why an exchange produced no response.
public enum AnalysisHTTPFailure: Error, Sendable, Hashable {
    /// The deadline passed before the whole body was read.
    case timeout
    /// The request never reached the provider or the body stream failed.
    case network
    /// The body grew past the cap.
    case oversizedBody
}

/// Sends one request and reads the whole response body.
public protocol AnalysisHTTPClient: Sendable {
    /// The exchange, send and body read, completes within `timeoutSeconds`
    /// or fails with ``AnalysisHTTPFailure/timeout``; a body larger than
    /// `maximumBodyBytes` fails with ``AnalysisHTTPFailure/oversizedBody``.
    func send(
        _ request: AnalysisHTTPRequest,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse
}
