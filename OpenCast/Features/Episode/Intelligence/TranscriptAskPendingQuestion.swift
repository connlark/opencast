import Foundation

/// The question the sheet is answering; a fresh id per send so the
/// view's task restarts (and cancels the previous turn on dismissal).
struct TranscriptAskPendingQuestion: Identifiable, Equatable {
    let id = UUID()
    let text: String
}
