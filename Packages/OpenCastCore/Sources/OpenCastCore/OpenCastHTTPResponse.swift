import Foundation

public struct OpenCastHTTPResponse: Sendable {
    public var url: URL?
    public var mimeType: String?
    public var expectedContentLength: Int64
    public var statusCode: Int?
    public var headers: [String: String]

    public init(
        url: URL?,
        mimeType: String?,
        expectedContentLength: Int64,
        statusCode: Int?,
        headers: [String: String]
    ) {
        self.url = url
        self.mimeType = mimeType
        self.expectedContentLength = expectedContentLength
        self.statusCode = statusCode
        self.headers = headers
    }

    public init(_ response: URLResponse) {
        let httpResponse = response as? HTTPURLResponse
        self.init(
            url: response.url,
            mimeType: response.mimeType,
            expectedContentLength: response.expectedContentLength,
            statusCode: httpResponse?.statusCode,
            headers: httpResponse.map(Self.normalizedHeaders(from:)) ?? [:]
        )
    }

    public func headerValue(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    private static func normalizedHeaders(from response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return headers
    }
}
