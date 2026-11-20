import Foundation

/// A fresh id per send restarts the view's task, which cancels the previous turn.
struct TranscriptAskPendingQuestion: Identifiable, Equatable {
    let id = UUID()
    let text: String
}
