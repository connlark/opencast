import Foundation

nonisolated struct StreamingAudioCacheManifest: Codable, Equatable, Sendable {
    var episodeID: String
    var podcastID: String?
    var originalURL: String
    var contentLength: Int64?
    var mimeType: String?
    var etag: String?
    var lastModified: String?
    var acceptsRanges: Bool
    var byteRanges: [StreamingAudioByteRange]
    var lastAccess: Date
    var lastValidation: Date?
    var validationState: StreamingAudioValidationState
    var isCompleted: Bool

    var hasValidator: Bool {
        etag?.isEmpty == false || lastModified?.isEmpty == false
    }

    func contains(_ range: Range<Int64>) -> Bool {
        byteRanges.contains { $0.contains(range) }
    }

    mutating func merge(_ range: Range<Int64>) {
        var ranges = byteRanges
        ranges.append(StreamingAudioByteRange(range))
        ranges.sort { $0.lowerBound < $1.lowerBound }

        var merged: [StreamingAudioByteRange] = []
        for range in ranges {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }

            if last.overlapsOrTouches(range) {
                merged[merged.count - 1] = last.merged(with: range)
            } else {
                merged.append(range)
            }
        }
        byteRanges = merged
    }
}
