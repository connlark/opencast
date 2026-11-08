import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import SwiftData
import Testing
@testable import OpenCast

/// The live environment over the real resolver: the one place the date and
/// the trial service's reachability meet. The store's tests script them as
/// independent facts, which in the app they are only through this wiring.
@MainActor
@Suite("Episode ad analysis live run environment")
struct EpisodeAdAnalysisLiveRunEnvironmentTests {
    private static let day = Date(timeIntervalSince1970: 1_793_000_000)

    private func snapshot(trialStartsIn seconds: TimeInterval) -> AnalysisPolicySnapshot {
        var bundle = AnalysisPolicyBundle.baked
        bundle.trial.startsAt = Date.now.addingTimeInterval(seconds)
        return AnalysisPolicySnapshot(bundle: bundle, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
    }

    private func makeEnvironment(
        _ stack: AnalysisRouteResolverTests.Stack,
        keyTier: AnalysisKeyTierStore = AnalysisKeyTierStore()
    ) -> EpisodeAdAnalysisLiveRunEnvironment {
        let policy = AnalysisPolicySnapshotStore.fixed(stack.snapshot)
        return EpisodeAdAnalysisLiveRunEnvironment(
            routes: stack.resolver,
            transports: AnalysisTransportFactory(
                policy: policy,
                runs: stack.runs,
                keys: stack.keys.storage,
                client: CapturingAnalysisHTTPClient()
            ),
            runs: stack.runs,
            usage: AnalysisUsageStore(),
            keyTier: keyTier,
            trialStatus: AnalysisTrialStatusCache(defaults: UserDefaults(suiteName: "opencast.live-env.\(UUID().uuidString)")!) { nil },
            policy: policy,
            presentKeyRequired: { _ in },
            holdsContinuedProcessingCard: { false }
        )
    }

    @Test("Before the date a service out of reach closes the window and leaves the date alone")
    func outOfReachBeforeTheDate() async {
        let stack = AnalysisRouteResolverTests.Stack(snapshot: snapshot(trialStartsIn: 3_600), isReachable: false)
        let environment = makeEnvironment(stack)

        #expect(await !environment.isHandoverWindowOpen())
        #expect(!environment.isPastTrialDate)
        guard case .unavailable = await environment.resolveHandover() else {
            Issue.record("a service out of reach read as the date")
            return
        }
    }

    @Test("Past the date the window is closed and the date says why, reachable or not", arguments: [true, false])
    func pastTheDate(isReachable: Bool) async {
        let stack = AnalysisRouteResolverTests.Stack(snapshot: snapshot(trialStartsIn: -3_600), isReachable: isReachable)
        let environment = makeEnvironment(stack)

        #expect(await !environment.isHandoverWindowOpen())
        #expect(environment.isPastTrialDate)
        guard case .notOpen = await environment.resolveHandover() else {
            Issue.record("past the date read as unavailable")
            return
        }
    }

    @Test("What Google answered is written with the time it is given")
    func writesTheAnswersTime() throws {
        let context = ModelContext(try OpenCastModelContainerFactory.make(inMemory: true))
        let keyTier = AnalysisKeyTierStore(now: { Self.day.addingTimeInterval(86_400) })
        let stack = AnalysisRouteResolverTests.Stack()
        let environment = makeEnvironment(stack, keyTier: keyTier)

        environment.noteGoogleKeyTier(.freeTier, answeredAt: Self.day, modelContext: context)
        #expect(keyTier.state == .freeTier(day: Self.day))

        environment.noteGoogleKeyTier(.inconclusive, answeredAt: Self.day, modelContext: context)
        #expect(keyTier.state == .freeTier(day: Self.day))

        environment.noteGoogleKeyTier(.notFreeTier, answeredAt: Self.day, modelContext: context)
        #expect(keyTier.state == .notFreeTier)
    }
}
