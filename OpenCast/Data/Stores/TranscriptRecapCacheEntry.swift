import Foundation

nonisolated struct TranscriptRecapCacheEntry: Codable, Equatable, Sendable {
    var key: TranscriptRecapCacheKey
    var result: TranscriptRecapResult
    var createdAt: Date
}
