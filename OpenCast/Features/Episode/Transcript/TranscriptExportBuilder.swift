import Foundation
import OpenCastTranscription

nonisolated enum TranscriptExportBuilder {
    #if DEBUG
    /// Test seam: pins that menu body evaluation never rebuilds exports —
    /// the strings are built once per document load, off the main actor.
    private static let buildCountLock = NSLock()
    nonisolated(unsafe) private static var lockedBuildCount = 0

    static var buildCount: Int {
        buildCountLock.withLock { lockedBuildCount }
    }

    static func resetBuildCount() {
        buildCountLock.withLock { lockedBuildCount = 0 }
    }

    private static func recordBuild() {
        buildCountLock.withLock { lockedBuildCount += 1 }
    }
    #endif

    static func plainText(from segments: [OpenCastTranscriptSegment]) -> String {
        #if DEBUG
        recordBuild()
        #endif
        return segments.map(\.text).joined(separator: "\n")
    }

    static func timestampedText(from segments: [OpenCastTranscriptSegment]) -> String {
        #if DEBUG
        recordBuild()
        #endif
        return segments
            .map { "[\($0.start.formattedPlaybackDuration)] \($0.text)" }
            .joined(separator: "\n")
    }
}
