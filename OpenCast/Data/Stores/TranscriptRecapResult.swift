import Foundation

/// A validated recap ready to render and cache. `isFromCache`, `usage`,
/// `latency`, and `attempts` describe how this instance was obtained and are
/// not part of the cached value.
nonisolated struct TranscriptRecapResult: Codable, Equatable, Sendable {
    var kind: TranscriptRecapWindowKind
    var playhead: TimeInterval
    var windowStart: TimeInterval
    var windowEnd: TimeInterval
    var windowSegmentCount: Int
    var windowTokenCount: Int
    var isWindowTruncated: Bool
    var bullets: [TranscriptRecapResultBullet]
    var droppedCitationCount: Int
    var isFromCache = false
    var usage: TranscriptIntelligenceUsage?
    var latency: TimeInterval?
    var attempts = 0

    private enum CodingKeys: String, CodingKey {
        case kind, playhead, windowStart, windowEnd, windowSegmentCount, windowTokenCount, isWindowTruncated, bullets, droppedCitationCount
    }
}
