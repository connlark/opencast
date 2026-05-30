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
