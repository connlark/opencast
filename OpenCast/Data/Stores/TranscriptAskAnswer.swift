import Foundation

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
