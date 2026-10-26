import OpenCastAnalysisProviders

/// The one-card rule across every continued-processing session: iOS holds
/// one card at a time, so the analysis session may arm only while the
/// ad-free pass, transcript generation and remote transcription cards are
/// all down, and those three refuse to arm while the analysis card is up.
/// A refused session runs in the foreground only. The app model holds this
/// object strongly; the analysis session holds it weakly.
final class AnalysisContinuedTaskArbiterImpl: AnalysisContinuedTaskArbiter {
    static let chaptersSummaryIdentifier = "com.connor.opencast.chapters-summary"

    /// The Chapters & Summary session, set by whoever builds it.
    weak var chaptersSummarySession: AnalysisExecutionSession?
    /// Whether any of the app's other cards is armed.
    var otherCardArmed: () -> Bool = { false }

    /// Whether the analysis session holds or has requested its card.
    var isAnalysisCardArmed: Bool {
        chaptersSummarySession?.isArmed ?? false
    }

    func mayArm(identifier: String) -> Bool {
        !otherCardArmed()
    }
}
