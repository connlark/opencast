import Foundation

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
