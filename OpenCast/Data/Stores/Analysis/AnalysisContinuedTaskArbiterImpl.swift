import OpenCastAnalysisProviders

/// The app model holds this strongly; the analysis session holds it weakly.
final class AnalysisContinuedTaskArbiterImpl: AnalysisContinuedTaskArbiter {
    static let chaptersSummaryIdentifier = "com.connor.opencast.chapters-summary"

    weak var chaptersSummarySession: AnalysisExecutionSession?
    var otherCardArmed: () -> Bool = { false }

    var isAnalysisCardArmed: Bool {
        chaptersSummarySession?.isArmed ?? false
    }

    func mayArm(identifier: String) -> Bool {
        !otherCardArmed()
    }
}
