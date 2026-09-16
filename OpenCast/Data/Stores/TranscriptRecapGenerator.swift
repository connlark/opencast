import Foundation

/// One recap request end to end: cache lookup, a token-budgeted window, one
/// structured PCC turn under the store's deadline, citation validation, and
/// the cache write. Retries once on malformed or wholly unverifiable output
/// and shrinks the window once when the model reports the context is full;
/// every other failure surfaces as the store recorded it.
final class TranscriptRecapGenerator {
    static let maximumResponseTokens = 700

    /// Everything one attempt produced, for the evaluation runner's report.
    struct Attempt: Sendable {
        var window: TranscriptRecapWindow
        var recap: TranscriptRecap?
        var validation: TranscriptRecapValidation?
        var failure: TranscriptIntelligenceFailure?
        var usage: TranscriptIntelligenceUsage?
        var latency: TimeInterval
    }

    private let store: TranscriptIntelligenceStore
    private let cache: TranscriptRecapCache
    var onAttempt: ((Attempt) -> Void)?

    init(store: TranscriptIntelligenceStore, cache: TranscriptRecapCache = TranscriptRecapCache()) {
        self.store = store
        self.cache = cache
    }

    func recap(
        document: EpisodeTranscriptDocument,
        kind: TranscriptRecapWindowKind,
        playhead: TimeInterval
    ) async throws -> TranscriptRecapResult {
        let key = TranscriptRecapCacheKey(
            document: document,
            kind: kind,
            playhead: playhead,
            modelIdentifier: store.modelIdentifier
        )
        if let cached = try? cache.entry(for: key) {
            var result = cached.result
            result.isFromCache = true
            return result
        }

        var tokenBudget = TranscriptRecapWindowBuilder.defaultTokenBudget
        var hasRetriedMalformedOutput = false
        var attempts = 0
        while true {
            try Task.checkCancellation()
            guard let window = try await TranscriptRecapWindowBuilder.build(
                kind: kind,
                segments: document.segments,
                playhead: playhead,
                tokenBudget: tokenBudget,
                tokenCount: store.tokenCount(for:)
            ) else {
                throw TranscriptRecapError.nothingToRecap(kind)
            }
            attempts += 1
            let clock = ContinuousClock()
            let started = clock.now
            do {
                let response: TranscriptIntelligenceResponse<TranscriptRecap>
                do {
                    response = try await respond(to: window)
                } catch {
                    onAttempt?(Attempt(
                        window: window,
                        failure: error as? TranscriptIntelligenceFailure,
                        latency: Self.seconds(clock.now - started)
                    ))
                    throw error
                }
                let validation = TranscriptCitationValidator.validate(response.content, window: window)
                onAttempt?(Attempt(
                    window: window,
                    recap: response.content,
                    validation: validation,
                    usage: response.usage,
                    latency: Self.seconds(clock.now - started)
                ))
                guard !validation.bullets.isEmpty else {
                    throw TranscriptIntelligenceFailure.malformedOutput
                }
                var result = TranscriptRecapResult(
                    kind: kind,
                    playhead: window.playhead,
                    windowStart: window.startTime,
                    windowEnd: window.endTime,
                    windowSegmentCount: window.segments.count,
                    windowTokenCount: window.tokenCount,
                    isWindowTruncated: window.isTruncated,
                    bullets: validation.bullets,
                    droppedCitationCount: validation.droppedCount
                )
                // A cache write failure only costs a repeat request later.
                try? cache.store(TranscriptRecapCacheEntry(key: key, result: result, createdAt: .now))
                result.usage = response.usage
                result.latency = Self.seconds(clock.now - started)
                result.attempts = attempts
                return result
            } catch TranscriptIntelligenceFailure.malformedOutput where !hasRetriedMalformedOutput {
                hasRetriedMalformedOutput = true
            } catch TranscriptIntelligenceFailure.contextSizeExceeded
                where tokenBudget / 2 >= TranscriptRecapWindowBuilder.minimumTokenBudget {
                tokenBudget /= 2
            }
        }
    }

    private func respond(to window: TranscriptRecapWindow) async throws -> TranscriptIntelligenceResponse<TranscriptRecap> {
        let session = store.makeSession(instructions: TranscriptIntelligencePrompts.recapInstructions, tools: [])
        let prompt = TranscriptIntelligencePrompts.recapPrompt(window: window)
        return try await store.perform {
            try await session.respond(
                to: prompt,
                generating: TranscriptRecap.self,
                options: TranscriptIntelligenceGenerationOptions(
                    maximumResponseTokens: Self.maximumResponseTokens,
                    toolCalling: .disallowed
                )
            )
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
