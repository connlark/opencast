import Foundation
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Transcript recap generator")
struct TranscriptRecapGeneratorTests {
    private let client = ScriptedTranscriptIntelligenceClient()
    private let store: TranscriptIntelligenceStore
    private let cache = TranscriptRecapCache(
        directory: URL.temporaryDirectory.appending(path: "recap-generator-\(UUID().uuidString)", directoryHint: .isDirectory)
    )
    private let document = TranscriptRecapTestFixtures.document(segments: TranscriptRecapTestFixtures.segments(count: 240))

    init() {
        store = TranscriptIntelligenceStore(client: client, isFeatureEnabled: true)
        store.refreshAvailability()
    }

    private func makeGenerator() -> TranscriptRecapGenerator {
        TranscriptRecapGenerator(store: store, cache: cache)
    }

    @Test("A valid recap is validated, cached, and served from the cache next time")
    func recapAndCache() async throws {
        defer { try? cache.removeAll() }
        client.turns = [.json(TranscriptRecapTestFixtures.recapJSON(citing: [31, 45, 59]))]
        let generator = makeGenerator()

        let result = try await generator.recap(document: document, kind: .lastFiveMinutes, playhead: 600)
        #expect(result.bullets.map(\.segmentID) == [31, 45, 59])
        #expect(result.bullets.map(\.start) == [310, 450, 590])
        #expect(result.windowStart == 300)
        #expect(result.windowEnd == 600)
        #expect(result.droppedCitationCount == 0)
        #expect(!result.isFromCache)
        #expect(result.attempts == 1)
        #expect(result.usage != nil)
        #expect(client.sessions.count == 1)
        #expect(client.sessions.first?.instructions == TranscriptIntelligencePrompts.recapInstructions)
        let prompt = try #require(client.sessions.first?.prompts.first)
        #expect(prompt.hasPrefix(TranscriptIntelligencePrompts.transcriptDataFraming))
        #expect(prompt.contains("[#59 9:50] Segment 59"))
        #expect(!prompt.contains("[#60 "))

        let again = try await generator.recap(document: document, kind: .lastFiveMinutes, playhead: 610)
        #expect(again.isFromCache)
        #expect(again.bullets == result.bullets)
        #expect(client.sessions.count == 1)
    }

    @Test("Unverifiable citations retry once, then fail as malformed output")
    func unverifiableCitationsRetryOnce() async throws {
        defer { try? cache.removeAll() }
        client.turns = [
            .json(TranscriptRecapTestFixtures.recapJSON(citing: [1, 2, 3])),
            .json(TranscriptRecapTestFixtures.recapJSON(citing: [40, 999, 50]))
        ]
        let generator = makeGenerator()
        var attempts: [TranscriptRecapGenerator.Attempt] = []
        generator.onAttempt = { attempts.append($0) }

        let result = try await generator.recap(document: document, kind: .lastFiveMinutes, playhead: 600)
        #expect(result.bullets.map(\.segmentID) == [40, 50])
        #expect(result.droppedCitationCount == 1)
        #expect(result.attempts == 2)
        #expect(attempts.count == 2)
        #expect(attempts.first?.validation?.droppedCount == 3)
        #expect(client.sessions.count == 2)

        client.turns = [
            .json(TranscriptRecapTestFixtures.recapJSON(citing: [1])),
            .failure(.malformedOutput)
        ]
        await #expect(throws: TranscriptIntelligenceFailure.malformedOutput) {
            _ = try await generator.recap(document: document, kind: .lastFiveMinutes, playhead: 1_200)
        }
        #expect(client.sessions.count == 4)
    }

    @Test("A guardrail violation surfaces once, with no retry and nothing cached")
    func guardrailDoesNotRetry() async throws {
        defer { try? cache.removeAll() }
        client.turns = [.failure(.guardrailViolation)]
        let generator = makeGenerator()

        await #expect(throws: TranscriptIntelligenceFailure.guardrailViolation) {
            _ = try await generator.recap(document: document, kind: .lastFiveMinutes, playhead: 600)
        }
        #expect(client.sessions.count == 1)
        #expect(store.lastFailure == .guardrailViolation)
        #expect(try cache.entry(for: TranscriptRecapCacheKey(document: document, kind: .lastFiveMinutes, playhead: 600, modelIdentifier: "scripted")) == nil)
    }

    @Test("A full context shrinks the window once and retries")
    func contextSizeShrinks() async throws {
        defer { try? cache.removeAll() }
        let wordy = TranscriptRecapTestFixtures.document(segments: TranscriptRecapTestFixtures.segments(count: 240, textLength: 900))
        client.turns = [
            .failure(.contextSizeExceeded(tokenCount: 7_000, contextSize: 6_500)),
            .json(TranscriptRecapTestFixtures.recapJSON(citing: [58, 59]))
        ]
        let generator = makeGenerator()

        let result = try await generator.recap(document: wordy, kind: .lastFiveMinutes, playhead: 600)
        #expect(result.bullets.map(\.segmentID) == [58, 59])
        #expect(result.isWindowTruncated)
        #expect(client.sessions.count == 2)
        let first = try #require(client.sessions[0].prompts.first)
        let second = try #require(client.sessions[1].prompts.first)
        #expect(second.count < first.count)
        #expect(result.windowTokenCount <= TranscriptRecapWindowBuilder.defaultTokenBudget / 2)
    }

    @Test("Too early a playhead throws nothing-to-recap without a request")
    func nothingToRecap() async throws {
        let generator = makeGenerator()
        await #expect(throws: TranscriptRecapError.nothingToRecap(.soFar)) {
            _ = try await generator.recap(document: document, kind: .soFar, playhead: 600)
        }
        #expect(client.sessions.isEmpty)
    }
}
