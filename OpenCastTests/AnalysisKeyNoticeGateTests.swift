import Foundation
import OpenCastAnalysis
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Analysis key notice gate")
struct AnalysisKeyNoticeGateTests {
    @Test("A tap runs at once while the notice is not due")
    func runsAtOnceWhenNotDue() throws {
        let appModel = try makeAppModel(noticeStarted: false)
        let gate = AnalysisKeyNoticeGate()
        var runs = 0

        gate.run(appModel: appModel) { runs += 1 }

        #expect(runs == 1)
        #expect(gate.pending == nil)
        #expect(!gate.isNoticePresented)
    }

    @Test("A due notice holds the tap and ignores another one")
    func holdsTapAndIgnoresRepeats() throws {
        let appModel = try makeAppModel(noticeStarted: true)
        let gate = AnalysisKeyNoticeGate()
        var firstRuns = 0
        var secondRuns = 0

        gate.run(appModel: appModel) { firstRuns += 1 }
        let held = gate.pending?.id
        gate.run(appModel: appModel) { secondRuns += 1 }

        #expect(firstRuns == 0)
        #expect(secondRuns == 0)
        #expect(held != nil)
        #expect(gate.pending?.id == held)
        #expect(gate.isNoticePresented)
    }

    @Test("Later marks the notice seen and runs the held tap once, after dismissal")
    func laterRunsTheHeldTapOnce() throws {
        let appModel = try makeAppModel(noticeStarted: true)
        let modelContext = try makeModelContext()
        let gate = AnalysisKeyNoticeGate()
        var runs = 0

        gate.run(appModel: appModel) { runs += 1 }
        gate.choose(.later, appModel: appModel, modelContext: modelContext)

        #expect(runs == 0)
        #expect(!gate.isNoticePresented)
        #expect(appModel.analysisKeyNotice.hasSeenAIKeyNotice)

        gate.didDismiss(appModel: appModel)
        #expect(runs == 1)
        #expect(gate.pending == nil)

        gate.didDismiss(appModel: appModel)
        #expect(runs == 1)

        // Seen now, so the next tap is not held.
        gate.run(appModel: appModel) { runs += 1 }
        #expect(runs == 2)
        #expect(!gate.isNoticePresented)
    }

    @Test("Add a key marks the notice seen, never runs the held tap and opens AI Services")
    func addKeyOpensAIServicesInstead() throws {
        let appModel = try makeAppModel(noticeStarted: true)
        let modelContext = try makeModelContext()
        let gate = AnalysisKeyNoticeGate()
        let requestsBefore = appModel.aiServicesSettingsPresentationRequest
        var runs = 0

        gate.run(appModel: appModel) { runs += 1 }
        gate.choose(.addKey, appModel: appModel, modelContext: modelContext)
        #expect(appModel.analysisKeyNotice.hasSeenAIKeyNotice)
        #expect(appModel.aiServicesSettingsPresentationRequest == requestsBefore)

        gate.didDismiss(appModel: appModel)
        #expect(runs == 0)
        #expect(appModel.aiServicesSettingsPresentationRequest == requestsBefore + 1)

        gate.didDismiss(appModel: appModel)
        #expect(runs == 0)
        #expect(appModel.aiServicesSettingsPresentationRequest == requestsBefore + 1)
    }

    @Test("A dismissal without a choice runs nothing and frees the gate")
    func dismissalWithoutChoiceRunsNothing() throws {
        let appModel = try makeAppModel(noticeStarted: true)
        let gate = AnalysisKeyNoticeGate()
        let requestsBefore = appModel.aiServicesSettingsPresentationRequest
        var runs = 0

        gate.run(appModel: appModel) { runs += 1 }
        gate.didDismiss(appModel: appModel)

        #expect(runs == 0)
        #expect(gate.pending == nil)
        #expect(!appModel.analysisKeyNotice.hasSeenAIKeyNotice)
        #expect(appModel.aiServicesSettingsPresentationRequest == requestsBefore)
    }

    /// The baked bundle with its notice moved to the distant past or future,
    /// no saved key, and an unseen notice.
    private func makeAppModel(noticeStarted: Bool) throws -> OpenCastAppModel {
        var bundle = AnalysisPolicySnapshot.baked.bundle
        try #require(bundle.notice != nil)
        bundle.notice?.startsAt = noticeStarted ? .distantPast : .distantFuture
        let snapshot = AnalysisPolicySnapshot(bundle: bundle, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
        return OpenCastAppModel(
            localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory(),
            analysisPolicy: .fixed(snapshot),
            analysisKeys: AnalysisProviderKeyStore(storage: InMemoryAnalysisProviderKeyStorage()),
            analysisKeyTester: FixedAnalysisKeyTester(),
            allowsAutomaticFeedRefresh: false
        )
    }

    private func makeModelContext() throws -> ModelContext {
        ModelContext(try OpenCastModelContainerFactory.make(inMemory: true))
    }
}
