import Foundation
import Testing
@testable import OpenCastTranscription
@preconcurrency import WhisperKit

/// F gate (whisper-perf pass 2): seed derivation is a pure function of
/// (audio hash, absolute window seek, attempt index) — the property that
/// makes a resumed window sample identically to the uninterrupted run, with
/// no global state and no cross-window coupling.
@Suite("Deterministic fallback seed derivation")
struct DeterministicFallbackSeedTests {
    @Test("Same inputs reproduce the same seed (resume property)")
    func sameInputsSameSeed() {
        // A resumed run reaching the same absolute seek with the same
        // attempt index must draw identical samples.
        let a = TranscribeTask.deterministicFallbackSeed(base: 0x0123_4567_89AB_CDEF, windowSeek: 4_800_000, attempt: 1)
        let b = TranscribeTask.deterministicFallbackSeed(base: 0x0123_4567_89AB_CDEF, windowSeek: 4_800_000, attempt: 1)
        #expect(a == b)
    }

    @Test("Seek, attempt, and audio identity all separate the seeds")
    func inputsSeparateSeeds() {
        let base: UInt64 = 0x0123_4567_89AB_CDEF
        let reference = TranscribeTask.deterministicFallbackSeed(base: base, windowSeek: 4_800_000, attempt: 1)
        #expect(TranscribeTask.deterministicFallbackSeed(base: base, windowSeek: 4_800_001, attempt: 1) != reference)
        #expect(TranscribeTask.deterministicFallbackSeed(base: base, windowSeek: 4_800_000, attempt: 2) != reference)
        #expect(TranscribeTask.deterministicFallbackSeed(base: base &+ 1, windowSeek: 4_800_000, attempt: 1) != reference)
    }

    @Test("Base seed derives stably from the audio hash prefix")
    func baseSeedFromHash() {
        let sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        #expect(OpenCastTranscriptionService.deterministicFallbackBaseSeed(from: sha) == 0x0123_4567_89AB_CDEF)
        #expect(OpenCastTranscriptionService.deterministicFallbackBaseSeed(from: "short") == nil)
        #expect(OpenCastTranscriptionService.deterministicFallbackBaseSeed(from: "zzzzzzzzzzzzzzzz") == nil)
    }

    @Test("Seeded sampler draws a reproducible sequence; unseeded does not share it")
    func seededSamplerSequence() {
        var first = SplitMix64RandomNumberGenerator(state: 42)
        var second = SplitMix64RandomNumberGenerator(state: 42)
        let sequenceA = (0..<8).map { _ in Float.random(in: 0..<1, using: &first) }
        let sequenceB = (0..<8).map { _ in Float.random(in: 0..<1, using: &second) }
        #expect(sequenceA == sequenceB)
        var shifted = SplitMix64RandomNumberGenerator(state: 43)
        let sequenceC = (0..<8).map { _ in Float.random(in: 0..<1, using: &shifted) }
        #expect(sequenceA != sequenceC)
    }
}
