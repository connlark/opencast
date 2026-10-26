import OpenCastAnalysis
import OpenCastAnalysisProviders
import SwiftData

/// What a device ad-detection run needs from the app around the store: the
/// run's route and transport, the run records, the listener's usage, the
/// trial status and the key screen. The app model builds the live one from
/// its analysis members; tests inject a scripted one.
protocol EpisodeAdAnalysisRunEnvironment: AnyObject {
    /// The run records both analysis features share.
    var runs: AnalysisRunRecordStore { get }
    /// The active bundle's ad-detection revision. A failure retained under
    /// another revision no longer pauses automatic retries.
    var adDetectionPolicyRevision: String { get }
    /// Whether a continued-processing card holds the run right now.
    var holdsContinuedProcessingCard: Bool { get }
    /// The clock a run's budget and backoff read.
    var clock: any AnalysisClock { get }

    /// The route for one run; `resumingRunID` names a run record to resume
    /// under the same id.
    func resolveRoute(resumingRunID: String?) async -> AnalysisRouteResolution

    /// The run's transport. It answers a resumed run's earlier replies from
    /// the run's sidecar and calls `onReused` for each.
    func makeTransport(
        for resolution: AnalysisRouteResolution,
        runID: String,
        observer: any AnalysisProviderSendObserver,
        onReused: @escaping @Sendable (AnalysisProviderRequest) -> Void
    ) throws(AnalysisTransportFactoryError) -> any AnalysisProviderTransport

    /// Counts a run on the listener's key: the counts are the run's totals
    /// so far, and only their growth since the last count under `runID`
    /// adds. Returns whether the count was saved.
    func recordUsage(
        provider: AnalysisProvider,
        inputTokens: Int,
        outputTokens: Int,
        runID: String,
        modelContext: ModelContext
    ) -> Bool

    /// Why a direct run lost the listener's key mid-run (removed, replaced
    /// or unreadable), when one of its sends found it gone.
    func keyRemoval(runID: String) -> AnalysisKeyRequiredReason?

    /// Reads the trial status again after the trial refused a run for its
    /// allowance; returns at once.
    func refreshTrialStatus()

    /// Shows the key screen for ad detection.
    func presentKeyRequired(_ reason: AnalysisKeyRequiredReason)
}
