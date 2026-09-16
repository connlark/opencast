import Foundation

/// One row of the Ask conversation. Assistant rows move from streaming text
/// to a validated answer or a per-turn failure; the session itself
/// continues either way.
struct TranscriptAskMessage: Identifiable, Equatable {
    enum Content: Equatable {
        case question(String)
        case streaming(String)
        case answer(TranscriptAskAnswer)
        case failure(TranscriptIntelligenceFailure)
    }

    let id = UUID()
    var content: Content

    var isStreaming: Bool {
        if case .streaming = content {
            return true
        }
        return false
    }
}
