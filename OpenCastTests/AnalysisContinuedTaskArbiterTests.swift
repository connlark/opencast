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

    func makeSession(_ scheduler: Scheduler, arbiter: AnalysisContinuedTaskArbiterImpl) -> AnalysisExecutionSession {
        AnalysisExecutionSession(
            identifier: AnalysisContinuedTaskArbiterImpl.chaptersSummaryIdentifier,
            title: "Chapters & Summary",
            scheduler: scheduler,
            arbiter: arbiter
        )
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
        #expect(await waitUntil { scheduler.submitted == [AnalysisContinuedTaskArbiterImpl.chaptersSummaryIdentifier] })
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
}
