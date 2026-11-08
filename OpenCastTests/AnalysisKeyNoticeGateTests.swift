import Foundation
import OpenCastAnalysis
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Analysis key notice gate")
struct AnalysisKeyNoticeGateTests {
    @Test("A tap runs at once while the notice is not due")
    func runsAtOnceWhenNotDue() async throws {
        let appModel = await makeAppModel(reachable: false)
        let gate = AnalysisKeyNoticeGate()
        var runs = 0

        gate.run(appModel: appModel) { runs += 1 }

        #expect(runs == 1)
        #expect(gate.pending == nil)
        #expect(!gate.isNoticePresented)
    }

    @Test("A saved key needs no answer about reachability: the tap runs at once")
    func savedKeyDoesNotWaitForReachability() throws {
        let answer = HeldReachabilityAnswer()
        let appModel = makeAppModel(reachability: AnalysisTrialReachability(read: answer.read))
        try appModel.analysisKeys.save(AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText), provider: .google, syncs: true)
        let gate = AnalysisKeyNoticeGate()
        var runs = 0

        gate.run(appModel: appModel) { runs += 1 }

        #expect(runs == 1)
        #expect(gate.pending == nil)
    }

    @Test("A due notice holds the tap and ignores another one")
    func holdsTapAndIgnoresRepeats() async throws {
        let appModel = await makeAppModel(reachable: true)
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

    @Test("A tap held while reachability is unknown shows the notice when it resolves available")
    func heldTapShowsTheNoticeWhenAvailable() async throws {
        let answer = HeldReachabilityAnswer()
        let appModel = makeAppModel(reachability: AnalysisTrialReachability(read: answer.read))
        let modelContext = try makeModelContext()
        let gate = AnalysisKeyNoticeGate()
        var runs = 0
        var repeatRuns = 0

        gate.run(appModel: appModel) { runs += 1 }
        let held = gate.pending?.id
        gate.run(appModel: appModel) { repeatRuns += 1 }

        #expect(held != nil)
        #expect(gate.pending?.id == held)
        #expect(!gate.isNoticePresented)
        #expect(runs == 0)

        answer.give(true)
        await settle { gate.isNoticePresented }

        #expect(gate.isNoticePresented)
        #expect(gate.pending?.id == held)
        #expect(runs == 0)

        gate.choose(.ok, appModel: appModel, modelContext: modelContext)
        gate.didDismiss()
        #expect(runs == 1)
        #expect(repeatRuns == 0)
    }

    @Test("A tap held while reachability is unknown runs, and is cleared, when it resolves unavailable")
    func heldTapRunsWhenUnavailable() async throws {
        let answer = HeldReachabilityAnswer()
        let appModel = makeAppModel(reachability: AnalysisTrialReachability(read: answer.read))
        let gate = AnalysisKeyNoticeGate()
        var runs = 0

        gate.run(appModel: appModel) { runs += 1 }
        #expect(gate.pending != nil)
        #expect(runs == 0)

        answer.give(false)
        await settle { runs > 0 }

        #expect(runs == 1)
        #expect(gate.pending == nil)
        #expect(!gate.isNoticePresented)

        // Cleared: the next tap is not swallowed as a repeat.
        gate.run(appModel: appModel) { runs += 1 }
        #expect(runs == 2)
    }

    @Test("A key saved during the hold runs the tap with no notice")
    func keySavedDuringTheHoldRunsTheTap() async throws {
        let answer = HeldReachabilityAnswer()
        let appModel = makeAppModel(reachability: AnalysisTrialReachability(read: answer.read))
        let gate = AnalysisKeyNoticeGate()
        var runs = 0

        gate.run(appModel: appModel) { runs += 1 }
        try appModel.analysisKeys.save(AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText), provider: .google, syncs: true)
        answer.give(true)
        await settle { runs > 0 }

        #expect(runs == 1)
        #expect(gate.pending == nil)
        #expect(!gate.isNoticePresented)
    }

    @Test("OK marks the notice seen and runs the held tap once, after dismissal")
    func okRunsTheHeldTapOnce() async throws {
        let appModel = await makeAppModel(reachable: true)
        let modelContext = try makeModelContext()
        let gate = AnalysisKeyNoticeGate()
        var runs = 0

        gate.run(appModel: appModel) { runs += 1 }
        gate.choose(.ok, appModel: appModel, modelContext: modelContext)

        #expect(runs == 0)
        #expect(!gate.isNoticePresented)
        #expect(appModel.analysisKeyNotice.hasSeenAIKeyNotice)

        gate.didDismiss()
        #expect(runs == 1)
        #expect(gate.pending == nil)
        #expect(gate.helpDestination == nil)

        gate.didDismiss()
        #expect(runs == 1)

        // Seen now, so the next tap is not held.
        gate.run(appModel: appModel) { runs += 1 }
        #expect(runs == 2)
        #expect(!gate.isNoticePresented)
    }

    @Test("Learn More marks the notice seen, never runs the held tap and opens the keys help")
    func learnMoreOpensTheKeysHelp() async throws {
        let appModel = await makeAppModel(reachable: true)
        let modelContext = try makeModelContext()
        let gate = AnalysisKeyNoticeGate()
        let requestsBefore = appModel.aiServicesSettingsPresentationRequest
        var runs = 0

        gate.run(appModel: appModel) { runs += 1 }
        gate.choose(.learnMore, appModel: appModel, modelContext: modelContext)
        #expect(appModel.analysisKeyNotice.hasSeenAIKeyNotice)
        #expect(gate.helpDestination == nil)

        gate.didDismiss()
        #expect(runs == 0)
        #expect(gate.pending == nil)
        #expect(gate.helpDestination?.id == SheetDestination.helpTopic(id: "ai-keys").id)
        #expect(appModel.aiServicesSettingsPresentationRequest == requestsBefore)

        gate.helpDestination = nil
        gate.didDismiss()
        #expect(runs == 0)
        #expect(gate.helpDestination == nil)
    }

    @Test("A dismissal without a choice runs nothing and frees the gate")
    func dismissalWithoutChoiceRunsNothing() async throws {
        let appModel = await makeAppModel(reachable: true)
        let gate = AnalysisKeyNoticeGate()
        var runs = 0

        gate.run(appModel: appModel) { runs += 1 }
        gate.didDismiss()

        #expect(runs == 0)
        #expect(gate.pending == nil)
        #expect(gate.helpDestination == nil)
        #expect(!appModel.analysisKeyNotice.hasSeenAIKeyNotice)
    }

    /// No saved key, an unseen notice and reachability already resolved.
    private func makeAppModel(reachable: Bool) async -> OpenCastAppModel {
        let reachability = AnalysisTrialReachability { reachable }
        await reachability.resolve()
        return makeAppModel(reachability: reachability)
    }

    private func makeAppModel(reachability: AnalysisTrialReachability) -> OpenCastAppModel {
        OpenCastAppModel(
            localLibraryCacheStore: SQLiteLocalLibraryCacheStore.inMemory(),
            analysisPolicy: .fixed(.baked),
            analysisKeys: AnalysisProviderKeyStore(storage: InMemoryAnalysisProviderKeyStorage()),
            analysisKeyTester: FixedAnalysisKeyTester(),
            analysisTrialReachability: reachability,
            allowsAutomaticFeedRefresh: false
        )
    }

    private func makeModelContext() throws -> ModelContext {
        ModelContext(try OpenCastModelContainerFactory.make(inMemory: true))
    }

    /// Lets the gate's task finish after the shared resolution has.
    private func settle(until isDone: () -> Bool) async {
        for _ in 0..<1_000 where !isDone() {
            await Task.yield()
        }
    }
}

/// Keeps reachability unknown until a test gives the answer.
private struct HeldReachabilityAnswer: Sendable {
    private let answers: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        (answers, continuation) = AsyncStream.makeStream()
    }

    var read: @Sendable () async -> Bool {
        { [answers] in
            for await answer in answers {
                return answer
            }
            return false
        }
    }

    func give(_ answer: Bool) {
        continuation.yield(answer)
    }
}
