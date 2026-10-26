import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Testing
@testable import OpenCast

@MainActor
@Suite("Analysis continued-task arbiter")
struct AnalysisContinuedTaskArbiterTests {
    @MainActor
    final class Handle: AnalysisContinuedTaskHandle {
        let progress = Progress(totalUnitCount: 0)
        private(set) var completions: [Bool] = []

        func updateTitle(_ title: String, subtitle: String) {}
        func setTaskCompleted(success: Bool) { completions.append(success) }
        func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {}
    }

    @MainActor
    final class Scheduler: AnalysisContinuedTaskScheduling {
        private(set) var submitted: [String] = []
        private var launch: (@MainActor @Sendable (any AnalysisContinuedTaskHandle) -> Void)?

        func registerLaunchHandler(
            identifier: String,
            onLaunch: @escaping @MainActor @Sendable (any AnalysisContinuedTaskHandle) -> Void
        ) -> Bool {
            launch = onLaunch
            return true
        }

        func submit(identifier: String, title: String, subtitle: String) async throws {
            submitted.append(identifier)
        }

        func cancel(identifier: String) {}

        func launchCard(_ handle: Handle) { launch?(handle) }
    }

    /// A run the test finishes by hand.
    final class Work: Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            (stream, continuation) = AsyncStream.makeStream()
        }

        func run() async -> AnalysisOutcome {
            for await _ in stream { break }
            return .failed(AnalysisFailure(feature: .chaptersSummary, code: .cancelled, status: 503))
        }

        func finish() { continuation.yield() }
    }

    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    func makeSession(_ scheduler: Scheduler, arbiter: AnalysisContinuedTaskArbiterImpl) -> AnalysisExecutionSession {
        AnalysisExecutionSession(
            identifier: AnalysisContinuedTaskArbiterImpl.chaptersSummaryIdentifier,
            title: "Chapters & Summary",
            scheduler: scheduler,
            arbiter: arbiter
        )
    }

    @Test("The analysis card may arm only while no other card is armed")
    func mayArmFollowsOtherCards() {
        let arbiter = AnalysisContinuedTaskArbiterImpl()
        #expect(arbiter.mayArm(identifier: AnalysisContinuedTaskArbiterImpl.chaptersSummaryIdentifier))

        var otherArmed = true
        arbiter.otherCardArmed = { otherArmed }
        #expect(!arbiter.mayArm(identifier: AnalysisContinuedTaskArbiterImpl.chaptersSummaryIdentifier))
        otherArmed = false
        #expect(arbiter.mayArm(identifier: AnalysisContinuedTaskArbiterImpl.chaptersSummaryIdentifier))
    }

    @Test("A session the arbiter refuses runs in the foreground and never shows as armed")
    func refusedSessionStaysDown() async {
        let arbiter = AnalysisContinuedTaskArbiterImpl()
        arbiter.otherCardArmed = { true }
        let scheduler = Scheduler()
        let session = makeSession(scheduler, arbiter: arbiter)
        arbiter.chaptersSummarySession = session
        let work = Work()

        let run = Task { await session.run(subtitle: "Episode", expectedSeconds: 60) { await work.run() } }
        await settle()

        #expect(session.state == .foregroundOnly)
        #expect(!arbiter.isAnalysisCardArmed)
        #expect(scheduler.submitted.isEmpty)
        work.finish()
        _ = await run.value
    }

    @Test("isAnalysisCardArmed follows the session's card from request through finish")
    func armedFollowsTheSession() async {
        let arbiter = AnalysisContinuedTaskArbiterImpl()
        let scheduler = Scheduler()
        let running = makeSession(scheduler, arbiter: arbiter)
        arbiter.chaptersSummarySession = running
        #expect(!arbiter.isAnalysisCardArmed)

        let work = Work()
        let run = Task { await running.run(subtitle: "Episode", expectedSeconds: 60) { await work.run() } }
        await settle()
        #expect(scheduler.submitted == [AnalysisContinuedTaskArbiterImpl.chaptersSummaryIdentifier])
        #expect(arbiter.isAnalysisCardArmed)

        let handle = Handle()
        scheduler.launchCard(handle)
        #expect(running.state == .running)
        #expect(arbiter.isAnalysisCardArmed)

        work.finish()
        _ = await run.value
        #expect(!arbiter.isAnalysisCardArmed)
        #expect(handle.completions.count == 1)
    }

    @Test("The arbiter holds the session weakly: a released session reads as down")
    func sessionHeldWeakly() {
        let arbiter = AnalysisContinuedTaskArbiterImpl()
        let scheduler = Scheduler()
        do {
            let session = makeSession(scheduler, arbiter: arbiter)
            arbiter.chaptersSummarySession = session
            #expect(arbiter.chaptersSummarySession === session)
        }
        #expect(arbiter.chaptersSummarySession == nil)
        #expect(!arbiter.isAnalysisCardArmed)
    }
}
