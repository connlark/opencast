import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Transcript intelligence store")
struct TranscriptIntelligenceStoreTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let client = ScriptedTranscriptIntelligenceClient()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        container = try ModelContainer(
            for: LocalPreferenceRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        context = ModelContext(container)
    }

    private func makeStore(
        isFeatureEnabled: Bool = true,
        clock: Clock = Clock()
    ) -> TranscriptIntelligenceStore {
        let store = TranscriptIntelligenceStore(client: client, isFeatureEnabled: isFeatureEnabled, now: { clock.now })
        store.load(modelContext: context)
        return store
    }

    final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @Test("Load resolves availability and visibility from the client")
    func loadResolvesAvailability() {
        let store = makeStore()
        #expect(store.availability == .available)
        #expect(store.isVisible)

        client.modelAvailability = .deviceNotEligible
        store.refreshAvailability()
        #expect(store.availability == .unsupportedDevice)
        #expect(!store.isVisible)

        client.modelAvailability = .appleIntelligenceNotEnabled
        store.refreshAvailability()
        #expect(store.availability == .appleIntelligenceOff)
        #expect(store.isVisible)
    }

    @Test("The feature flag hides the entry points even when available")
    func featureFlagHides() {
        let store = makeStore(isFeatureEnabled: false)
        #expect(store.availability == .available)
        #expect(!store.isVisible)
    }

    @Test("The disclosure acknowledgement persists across loads")
    func disclosurePersists() {
        let store = makeStore()
        #expect(!store.hasAcknowledgedDisclosure)

        store.acknowledgeDisclosure(modelContext: context)
        #expect(store.hasAcknowledgedDisclosure)

        let reloaded = makeStore()
        #expect(reloaded.hasAcknowledgedDisclosure)

        try? LocalPreferenceRecord.deletePreferences(
            forKey: TranscriptIntelligenceStore.disclosureAcknowledgedPreferenceKey,
            modelContext: context
        )
        let afterNuke = makeStore()
        #expect(!afterNuke.hasAcknowledgedDisclosure)
    }

    @Test("A successful request clears the last failure and refreshes quota")
    func successClearsFailure() async throws {
        let store = makeStore()
        client.turns = [.failure(.timeout), .text("recap")]
        let session = store.makeSession(instructions: "instructions", tools: [])

        await #expect(throws: TranscriptIntelligenceFailure.timeout) {
            _ = try await store.perform { try await session.respond(to: "one", options: TranscriptIntelligenceGenerationOptions()) }
        }
        #expect(store.lastFailure == .timeout)
        #expect(store.availability == .available)

        client.quota = TranscriptIntelligenceQuotaSnapshot(isApproachingLimit: true)
        let response = try await store.perform {
            try await session.respond(to: "two", options: TranscriptIntelligenceGenerationOptions())
        }
        #expect(response.content == "recap")
        #expect(store.lastFailure == nil)
        #expect(store.quota.isApproachingLimit)
        #expect(client.sessions.first?.instructions == "instructions")
        #expect(client.sessions.first?.prompts == ["one", "two"])
    }

    @Test("A rate limit blocks until its backoff expires and survives refresh")
    func rateLimitBacksOff() async {
        let clock = Clock()
        let store = makeStore(clock: clock)
        client.turns = [.failure(.rateLimited(resetDate: nil))]
        let session = store.makeSession(instructions: "", tools: [])

        await #expect(throws: TranscriptIntelligenceFailure.rateLimited(resetDate: nil)) {
            _ = try await store.perform { try await session.respond(to: "q", options: TranscriptIntelligenceGenerationOptions()) }
        }
        let retryDate = clock.now.addingTimeInterval(TranscriptIntelligenceAvailability.rateLimitBackoff)
        #expect(store.availability == .quotaReached(resetDate: retryDate))
        #expect(store.isVisible)

        store.refreshAvailability()
        #expect(store.availability == .quotaReached(resetDate: retryDate))
        #expect(store.lastFailure == .rateLimited(resetDate: nil))

        clock.now = retryDate
        store.refreshAvailability()
        #expect(store.availability == .available)
    }

    @Test("Offline reads as offline until the next refresh")
    func offlineClearsOnRefresh() async {
        let store = makeStore()
        client.turns = [.failure(.offline)]
        let session = store.makeSession(instructions: "", tools: [])

        await #expect(throws: TranscriptIntelligenceFailure.offline) {
            _ = try await store.perform { try await session.respond(to: "q", options: TranscriptIntelligenceGenerationOptions()) }
        }
        #expect(store.availability == .offline)
        #expect(store.lastFailure == .offline)

        store.refreshAvailability()
        #expect(store.availability == .available)
        #expect(store.lastFailure == nil)
    }

    @Test("An unentitled build hides the feature for the rest of the process")
    func notEntitledHides() async {
        let store = makeStore()
        client.turns = [.failure(.notEntitled)]
        let session = store.makeSession(instructions: "", tools: [])

        await #expect(throws: TranscriptIntelligenceFailure.notEntitled) {
            _ = try await store.perform { try await session.respond(to: "q", options: TranscriptIntelligenceGenerationOptions()) }
        }
        #expect(store.availability == .notEntitled)
        #expect(!store.isVisible)

        store.refreshAvailability()
        #expect(store.availability == .notEntitled)
        #expect(!store.isVisible)
    }

    @Test("Guardrail declines are per-request outcomes that keep the feature available")
    func guardrailKeepsAvailable() async {
        let store = makeStore()
        client.turns = [.failure(.guardrailViolation)]
        let session = store.makeSession(instructions: "", tools: [])

        await #expect(throws: TranscriptIntelligenceFailure.guardrailViolation) {
            _ = try await store.perform { try await session.respond(to: "q", options: TranscriptIntelligenceGenerationOptions()) }
        }
        #expect(store.lastFailure == .guardrailViolation)
        #expect(store.availability == .available)
    }

    @Test("Cancellation leaves no trace")
    func cancellationLeavesNoTrace() async {
        let store = makeStore()
        client.turns = [.failure(.cancelled)]
        let session = store.makeSession(instructions: "", tools: [])

        await #expect(throws: TranscriptIntelligenceFailure.cancelled) {
            _ = try await store.perform { try await session.respond(to: "q", options: TranscriptIntelligenceGenerationOptions()) }
        }
        #expect(store.lastFailure == nil)
        #expect(store.availability == .available)
    }

    @Test("A hung request times out at the deadline and stays available")
    func hungRequestTimesOut() async {
        let store = makeStore()
        client.turns = [.hang]
        let session = store.makeSession(instructions: "", tools: [])

        await #expect(throws: TranscriptIntelligenceFailure.timeout) {
            _ = try await store.perform(deadline: .milliseconds(50)) {
                try await session.respond(to: "q", options: TranscriptIntelligenceGenerationOptions())
            }
        }
        #expect(store.lastFailure == .timeout)
        #expect(store.availability == .available)
    }

    @Test("Foreign errors are mapped before they are recorded")
    func foreignErrorsAreMapped() async {
        let store = makeStore()

        await #expect(throws: TranscriptIntelligenceFailure.offline) {
            try await store.perform { throw URLError(.notConnectedToInternet) }
        }
        #expect(store.availability == .offline)

        await #expect(throws: TranscriptIntelligenceFailure.cancelled) {
            try await store.perform { throw CancellationError() }
        }
        #expect(store.availability == .offline)

        await #expect(throws: TranscriptIntelligenceFailure.notEntitled) {
            try await store.perform {
                throw NSError(
                    domain: "ModelManagerServices.ModelManagerError",
                    code: 1046,
                    userInfo: [NSLocalizedDescriptionKey: "not entitled"]
                )
            }
        }
        #expect(store.availability == .notEntitled)
    }
}
