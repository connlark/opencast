import Foundation

nonisolated struct ArtworkDiskCacheMetadata: Codable, Equatable, Sendable {
    var canonicalURL: String
    var sourceURL: String
    var mimeType: String?
    var etag: String?
    var lastModified: String?
    var byteCount: Int
    var lastAccess: Date
    var lastValidation: Date
    var preview: ArtworkPreview?

    private enum CodingKeys: String, CodingKey {
        case canonicalURL
        case sourceURL
        case mimeType
        case etag
        case lastModified
        case byteCount
        case lastAccess
        case lastValidation
        case preview
    }

    init(
        canonicalURL: String,
        sourceURL: String,
        mimeType: String?,
        etag: String?,
        lastModified: String?,
        byteCount: Int,
        lastAccess: Date,
        lastValidation: Date,
        preview: ArtworkPreview?
    ) {
        self.canonicalURL = canonicalURL
        self.sourceURL = sourceURL
        self.mimeType = mimeType
        self.etag = etag
        self.lastModified = lastModified
        self.byteCount = byteCount
        self.lastAccess = lastAccess
        self.lastValidation = lastValidation
        self.preview = preview
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canonicalURL = try container.decode(String.self, forKey: .canonicalURL)
        sourceURL = try container.decode(String.self, forKey: .sourceURL)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        lastModified = try container.decodeIfPresent(String.self, forKey: .lastModified)
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        lastAccess = try container.decode(Date.self, forKey: .lastAccess)
        lastValidation = try container.decode(Date.self, forKey: .lastValidation)
        preview = try? container.decodeIfPresent(ArtworkPreview.self, forKey: .preview)
    }

    var hasValidator: Bool {
        validatorHeaderFields.isEmpty == false
    }

    var validatorHeaderFields: [String: String] {
        var fields: [String: String] = [:]
        if let etag, !etag.isEmpty {
            fields["If-None-Match"] = etag
        }
        if let lastModified, !lastModified.isEmpty {
            fields["If-Modified-Since"] = lastModified
        }
        return fields
    }

    func isStale(for kind: ArtworkCacheKind, now: Date = .now) -> Bool {
        guard hasValidator else {
            return false
        }

        return now.timeIntervalSince(lastValidation) >= kind.timeToLive
    }
}
