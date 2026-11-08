import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Testing
@testable import OpenCast

/// The key sheet's last Test: a new Test or an edit clears whether the key
/// was accepted and what Google said about its tier together.
@MainActor
@Suite("Analysis key test state")
struct AnalysisKeyTestStateTests {
    private static let key = AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText)

    private static func answer(_ result: AnalysisTierCheckResult) -> AnalysisKeyTierStore.Answer {
        AnalysisKeyTierStore.Answer(result: result, keyDigest: key.digest, answeredAt: .now)
    }

    private func footer(_ state: AnalysisKeyTestState) throws -> String {
        AnalysisKeyTestStatusLabel.text(for: try #require(state.result), isFreeTier: state.isFreeTier, provider: .google)
    }

    /// A state whose Test of `key` finished with `tier`.
    private func tested(_ tier: AnalysisTierCheckResult) throws -> AnalysisKeyTestState {
        var state = AnalysisKeyTestState()
        let started = state.start(key: Self.key)
        let landed = state.finish(.accepted, tier: Self.answer(tier), generation: try #require(started))
        #expect(landed)
        return state
    }

    @Test("A saved key that tested free tier and then went through the Keychain reads the failure on the next Test, never Key works")
    func failedSecondTest() throws {
        let storage = InMemoryAnalysisProviderKeyStorage(seeded: [.google: (Self.key, syncs: false)])
        let keys = AnalysisProviderKeyStore(storage: storage)
        var state = try tested(.freeTier)
        #expect(try footer(state) == AIServicesCopy.testResultFreeTier)

        storage.place(nil, provider: .google, synchronizable: false)
        let generation = state.start(key: try? keys.key(for: .google))

        #expect(generation == nil)
        #expect(state.result == .failed(.requestRejected))
        #expect(state.tier == nil)
        #expect(!state.isTesting)
        #expect(try footer(state) == AIServicesCopy.testResult(.failed(.requestRejected), provider: .google))
        #expect(try !footer(state).contains("Key works"))
    }

    @Test("A new Test clears the last one while it runs")
    func startClearsTheLastTest() throws {
        var state = try tested(.freeTier)
        let first = state.generation

        let second = state.start(key: Self.key)

        #expect(second != nil)
        #expect(second != first)
        #expect(state.isTesting)
        #expect(state.result == nil)
        #expect(!state.isFreeTier)
    }

    @Test("A Test whose draft is gone lands nothing")
    func staleTest() throws {
        var state = AnalysisKeyTestState()
        let started = state.start(key: Self.key)

        state.invalidate()
        let landed = state.finish(.accepted, tier: Self.answer(.freeTier), generation: try #require(started))

        #expect(!landed)
        #expect(state.result == nil)
        #expect(state.tier == nil)
        #expect(!state.isTesting)
    }

    @Test("An edit clears the result and the tier together")
    func invalidateClearsBoth() throws {
        var state = try tested(.freeTier)

        state.invalidate()

        #expect(state.result == nil)
        #expect(state.tier == nil)
    }

    @Test("An inconclusive check reads Key works, and only a free-tier answer changes it", arguments: [
        (AnalysisTierCheckResult.inconclusive, false), (.notFreeTier, false), (.freeTier, true),
    ])
    func acceptedKeyFooter(tier: AnalysisTierCheckResult, isFreeTier: Bool) throws {
        let state = try tested(tier)

        #expect(state.isFreeTier == isFreeTier)
        #expect(try footer(state) == (isFreeTier ? AIServicesCopy.testResultFreeTier : AIServicesCopy.testResult(.accepted, provider: .google)))
    }
}
