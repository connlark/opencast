import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import SwiftData

protocol EpisodeAdAnalysisRunEnvironment: AnyObject {
    var runs: AnalysisRunRecordStore { get }
    /// A failure retained under another revision no longer pauses automatic retries.
    var adDetectionPolicyRevision: String { get }
    var holdsContinuedProcessingCard: Bool { get }
    var clock: any AnalysisClock { get }

    func resolveRoute(resumingRunID: String?) async -> AnalysisRouteResolution

    /// Answers a resumed run's earlier replies from its sidecar, calling `onReused` for each.
    func makeTransport(
        for resolution: AnalysisRouteResolution,
        runID: String,
        observer: any AnalysisProviderSendObserver,
        onReused: @escaping @Sendable (AnalysisProviderRequest) -> Void
    ) throws(AnalysisTransportFactoryError) -> any AnalysisProviderTransport

    /// The counts are the run's totals so far; only their growth since the last count under
    /// `runID` adds.
    func recordUsage(
        provider: AnalysisProvider,
        inputTokens: Int,
        outputTokens: Int,
        runID: String,
        modelContext: ModelContext
    ) -> Bool

    func keyRemoval(runID: String) -> AnalysisKeyRequiredReason?

    /// Decides only whether to ask Google again, never a route.
    var googleKeyTier: AnalysisKeyTierStore.State { get }

    /// Check `keyChange` first, so an answer lands only on the key it was given for.
    func noteGoogleKeyTier(_ answer: AnalysisTierCheckResult, answeredAt: Date, modelContext: ModelContext)

    /// The time an answer is stamped with, read as the answer arrives.
    var now: Date { get }

    func resetGoogleKeyTier(modelContext: ModelContext)

    func checkTier(key: AnalysisProviderKey) async -> AnalysisTierCheckResult

    func keyChange(provider: AnalysisProvider, keyDigest: Data) -> AnalysisKeyRequiredReason?

    /// Whether a run may use the trial service for a free-tier key.
    func isHandoverWindowOpen() async -> Bool

    /// Past it a free-tier run closes for good; an unreachable trial service only makes it wait.
    var isPastTrialDate: Bool { get }

    func resolveHandover() async -> AnalysisHandoverResolution

    func refreshTrialStatus()

    func presentKeyRequired(_ reason: AnalysisKeyRequiredReason)
}
