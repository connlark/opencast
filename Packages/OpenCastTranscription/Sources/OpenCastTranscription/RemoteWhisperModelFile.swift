import Foundation

public struct RemoteWhisperModelFile: Codable, Sendable, Equatable {
    public var path: String
    public var urlPath: String
    public var byteCount: Int64
    public var sha256: String
    public var contentType: String

    public init(
        path: String,
        urlPath: String,
        byteCount: Int64,
        sha256: String,
        contentType: String
    ) {
        self.path = path
        self.urlPath = urlPath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.contentType = contentType
    }

    enum CodingKeys: String, CodingKey {
        case path
        case urlPath = "url_path"
        case byteCount = "byte_count"
        case sha256
        case contentType = "content_type"
    }
}
