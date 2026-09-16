import Foundation

/// A validated answer ready to render. `isVerified` is false when the model
/// claimed an answer but none of its citations survived validation, which
/// the sheet shows as text without chips plus a note, never silently.
nonisolated struct TranscriptAskAnswer: Equatable, Sendable {
    var text: String
    var isAnswerable: Bool
    var citations: [TranscriptAskCitation]
    var droppedCitationCount: Int
    var toolCallCount = 0
    var usage: TranscriptIntelligenceUsage?
    var latency: TimeInterval?

    var isVerified: Bool {
        !isAnswerable || !citations.isEmpty
    }
}
