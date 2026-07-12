import Foundation
import OpenCastTranscription

nonisolated enum TranscriptExportBuilder {
    static func plainText(from segments: [OpenCastTranscriptSegment]) -> String {
        segments.map(\.text).joined(separator: "\n")
    }

    static func timestampedText(from segments: [OpenCastTranscriptSegment]) -> String {
        segments
            .map { "[\($0.start.formattedPlaybackDuration)] \($0.text)" }
            .joined(separator: "\n")
    }
}
