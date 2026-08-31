import CoreML
import Foundation
import Testing
@preconcurrency import WhisperKit

/// Measure-only harness: quantifies what
/// GreedyTokenSampler.update spends copying complete token/log-prob history
/// arrays per token versus the delta the decoder actually consumes.
/// Opt-in via OPENCAST_SAMPLER_MICROBENCH=1.
@Suite("Sampler history copy microbenchmark", .serialized)
struct SamplerHistoryCopyMicrobenchmarkTests {
    private static let logitsCount = 51864
    private static let maxContext = 448

    @Test(
        "Timing pass",
        .enabled(if: ProcessInfo.processInfo.environment["OPENCAST_SAMPLER_MICROBENCH"] == "1")
    )
    func timingPass() async throws {

        let logits = try MLMultiArray(
            shape: [1, 1, NSNumber(value: Self.logitsCount)],
            dataType: .float16
        )
        logits.withUnsafeMutableBytes { pointer, _ in
            let buffer = pointer.bindMemory(to: Float16.self)
            for index in 0..<buffer.count {
                buffer[index] = Float16(sin(Double(index) * 0.37) * 4)
            }
        }

        let sampler = GreedyTokenSampler(
            temperature: 0,
            eotToken: 50256,
            decodingOptions: DecodingOptions()
        )
        let clock = ContinuousClock()

        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }

        // A: real sampler calls at representative history lengths.
        for historyLength in [0, 112, 224, 336, 447] {
            let tokens = [Int](repeating: 361, count: historyLength)
            let logProbs = [Float](repeating: -0.25, count: historyLength)
            let repeats = 50

            // Warmup.
            for _ in 0..<5 {
                _ = await sampler.update(tokens: tokens, logits: logits, logProbs: logProbs)
            }
            var consumed = 0
            let start = clock.now
            for _ in 0..<repeats {
                let result = await sampler.update(tokens: tokens, logits: logits, logProbs: logProbs)
                consumed &+= result.tokens.count
            }
            let wall = seconds(start.duration(to: clock.now))
            print("SAMPLER_MICROBENCH variant=fullUpdate history=\(historyLength) repeats=\(repeats) us_per_call=\(String(format: "%.1f", wall * 1e6 / Double(repeats))) sink=\(consumed)")
        }

        // B: pure history-copy pattern (what a delta protocol would remove),
        // simulated across one full window growth 0 -> maxContext.
        var sink = 0
        let rounds = 200
        let startCopies = clock.now
        for _ in 0..<rounds {
            var tokens: [Int] = []
            var logProbs: [Float] = []
            tokens.reserveCapacity(0)
            for step in 0..<Self.maxContext {
                // Mirrors SamplingResult construction: full copied arrays.
                let newTokens = tokens + [step]
                let newLogProbs = logProbs + [Float(step)]
                sink &+= newTokens.count &+ Int(newLogProbs.last ?? 0)
                // Mirrors TextDecoder keeping its own history via append.
                tokens.append(step)
                logProbs.append(Float(step))
            }
        }
        let copyWall = seconds(startCopies.duration(to: clock.now))
        let copiesPerWindow = copyWall / Double(rounds)
        print("SAMPLER_MICROBENCH variant=historyCopyPattern windows=\(rounds) us_per_window=\(String(format: "%.1f", copiesPerWindow * 1e6)) us_per_token_avg=\(String(format: "%.3f", copiesPerWindow * 1e6 / Double(Self.maxContext))) sink=\(sink)")

        // C: delta pattern for the same growth (decoder-side append only).
        var deltaSink = 0
        let startDelta = clock.now
        for _ in 0..<rounds {
            var tokens: [Int] = []
            var logProbs: [Float] = []
            for step in 0..<Self.maxContext {
                tokens.append(step)
                logProbs.append(Float(step))
                deltaSink &+= tokens.count &+ Int(logProbs.last ?? 0)
            }
        }
        let deltaWall = seconds(startDelta.duration(to: clock.now))
        print("SAMPLER_MICROBENCH variant=deltaPattern windows=\(rounds) us_per_window=\(String(format: "%.1f", deltaWall * 1e6 / Double(rounds))) sink=\(deltaSink)")
    }
}
