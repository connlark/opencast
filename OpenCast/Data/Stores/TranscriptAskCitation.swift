import Foundation

nonisolated struct TranscriptAskCitation: Identifiable, Equatable, Sendable {
    var segmentID: Int
    var start: TimeInterval

    var id: Int {
        segmentID
    }
}
