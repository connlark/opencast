import Foundation

/// A displayed Ask citation: the segment it names and that segment's start,
/// which the chip seeks to.
nonisolated struct TranscriptAskCitation: Identifiable, Equatable, Sendable {
    var segmentID: Int
    var start: TimeInterval

    var id: Int {
        segmentID
    }
}
