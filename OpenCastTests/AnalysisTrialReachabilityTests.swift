import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Analysis trial reachability")
struct AnalysisTrialReachabilityTests {
    private static let endpoint = URL(string: "https://trial.opencast.mobile")!

    @Test("It starts unknown and resolves to the answer", arguments: [true, false])
    func resolvesToTheAnswer(reachable: Bool) async {
        let reachability = AnalysisTrialReachability { reachable }
        #expect(reachability.state == .unknown)

        let resolved = await reachability.resolve()

        #expect(resolved == (reachable ? .available : .unavailable))
        #expect(reachability.state == resolved)
    }

    @Test("It reads once for the session, however many callers ask")
    func readsOnce() async {
        let reads = AnalysisTestCounter()
        let reachability = AnalysisTrialReachability {
            reads.add()
            return true
        }

        reachability.start()
        reachability.start()
        async let first = reachability.resolve()
        async let second = reachability.resolve()
        _ = await (first, second)
        await reachability.resolve()

        #expect(reads.count == 1)
    }

    @Test("The handover window needs the service reachable and the trial not begun")
    func handoverWindow() async {
        let start = Date(timeIntervalSince1970: 1_798_761_600)
        let before = start.addingTimeInterval(-1)

        let available = AnalysisTrialReachability { true }
        #expect(!available.isHandoverWindowOpen(trialStartsAt: start, now: before))
        await available.resolve()
        #expect(available.isHandoverWindowOpen(trialStartsAt: start, now: before))
        #expect(!available.isHandoverWindowOpen(trialStartsAt: start, now: start))
        #expect(!available.isHandoverWindowOpen(trialStartsAt: start, now: start.addingTimeInterval(1)))

        let unavailable = AnalysisTrialReachability { false }
        await unavailable.resolve()
        #expect(!unavailable.isHandoverWindowOpen(trialStartsAt: start, now: before))
    }

    @Test("A fixture connection with no bearer and no App Attest support reads available")
    func fixtureConnectionIsReachable() async {
        let connection = AnalysisTrialConnection(routing: .storeEnvironment, isFixture: true)

        #expect(await connection.isReachable(trialEndpoint: Self.endpoint))
    }

    @Test("An unknown store environment has no route")
    func unknownStoreEnvironmentIsUnreachable() async {
        let connection = AnalysisTrialConnection(routing: .storeEnvironment, storeEnvironment: { .unknown("test") })

        #expect(await !connection.isReachable(trialEndpoint: Self.endpoint))
    }

    @Test("A store environment that cannot be read has no route")
    func unreadableStoreEnvironmentIsUnreachable() async {
        struct Unreadable: Error {}
        let connection = AnalysisTrialConnection(routing: .storeEnvironment, storeEnvironment: { throw Unreadable() })

        #expect(await !connection.isReachable(trialEndpoint: Self.endpoint))
    }

    @Test("A configuration this device cannot sign for has no route")
    func unsignableConfigurationIsUnreachable() async {
        // The simulator cannot attest, and a store build signs only by App Attest.
        let connection = AnalysisTrialConnection(routing: .storeEnvironment, storeEnvironment: { .production })

        #expect(await !connection.isReachable(trialEndpoint: Self.endpoint))
    }
}
