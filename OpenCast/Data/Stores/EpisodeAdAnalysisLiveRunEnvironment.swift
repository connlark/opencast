import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import SwiftData

/// The app's run environment for device ad detection, over the app model's
/// route resolver, transport factory, run records, usage and trial status.
final class EpisodeAdAnalysisLiveRunEnvironment: EpisodeAdAnalysisRunEnvironment {
    let runs: AnalysisRunRecordStore
    let clock: any AnalysisClock = AnalysisSystemClock()
    private let routes: AnalysisRouteResolver
    private let transports: AnalysisTransportFactory
    private let usage: AnalysisUsageStore
    private let trialStatus: AnalysisTrialStatusCache
    private let policy: AnalysisPolicySnapshotStore
    private let presentsKeyRequired: (AnalysisKeyRequiredReason) -> Void
    private let isCardHeld: () -> Bool

    init(
        routes: AnalysisRouteResolver,
        transports: AnalysisTransportFactory,
        runs: AnalysisRunRecordStore,
        usage: AnalysisUsageStore,
        trialStatus: AnalysisTrialStatusCache,
        policy: AnalysisPolicySnapshotStore,
        presentKeyRequired: @escaping (AnalysisKeyRequiredReason) -> Void,
        holdsContinuedProcessingCard: @escaping () -> Bool
    ) {
        self.routes = routes
        self.transports = transports
        self.runs = runs
        self.usage = usage
        self.trialStatus = trialStatus
        self.policy = policy
        presentsKeyRequired = presentKeyRequired
        isCardHeld = holdsContinuedProcessingCard
    }

    var adDetectionPolicyRevision: String {
        policy.snapshot.bundle.features.adDetection.revision
    }

    var holdsContinuedProcessingCard: Bool {
        isCardHeld()
    }

    func resolveRoute(resumingRunID: String?) async -> AnalysisRouteResolution {
        await routes.resolve(feature: .adDetection, resumingRunID: resumingRunID)
    }

    func makeTransport(
        for resolution: AnalysisRouteResolution,
        runID: String,
        observer: any AnalysisProviderSendObserver,
        onReused: @escaping @Sendable (AnalysisProviderRequest) -> Void
    ) throws(AnalysisTransportFactoryError) -> any AnalysisProviderTransport {
        try transports.makeTransport(for: resolution, runID: runID, observer: observer, onReused: onReused)
    }

    func recordUsage(
        provider: AnalysisProvider,
        inputTokens: Int,
        outputTokens: Int,
        runID: String,
        modelContext: ModelContext
    ) -> Bool {
        usage.record(
            provider: provider,
            feature: .adDetection,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            at: .now,
            runID: runID,
            modelContext: modelContext
        )
    }

    func keyRemoval(runID: String) -> AnalysisKeyRequiredReason? {
        transports.keyRemoval(runID: runID)
    }

    func refreshTrialStatus() {
        Task { [trialStatus] in
            _ = await trialStatus.status(forceRefresh: true)
        }
    }

    func presentKeyRequired(_ reason: AnalysisKeyRequiredReason) {
        presentsKeyRequired(reason)
    }
}
