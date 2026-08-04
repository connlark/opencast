import CoreML
import Foundation
import Testing
@preconcurrency import WhisperKit

/// D3 gate (whisper-perf pass 2): the CPU greedy sampler must pick exactly
/// the same token as the MLTensor path it replaces on randomized and
/// adversarial Float16 tensors (including exact-value ties, suppressed
/// ranges, ±inf, NaN), and its log-prob must stay within the declared
/// tolerance so fallback-threshold decisions (avgLogProb −1.0,
/// firstTokenLogProb −1.5) cannot flip. Temperature > 0 sampling is
/// untouched by the spike and out of scope here.
///
/// Declared log-prob tolerances (restated after adversarial verification):
/// the CPU log-prob is gated against a float64 log-sum-exp reference at
/// |Δ| ≤ 1e-4 (observed CPU-vs-truth bound ~5e-5) and against the MLTensor
/// path at |Δ| ≤ 5e-4. The wider compat bound exists because MLTensor's own
/// softmax reduction error reaches ~2.5e-4 from truth on adversarial
/// near-flat tensors — the CPU path is the more accurate side of that gap.
/// Fallback-threshold flips are therefore confined to decisions within
/// ~5e-5 of −1.0/−1.5, where the replaced path is equally arbitrary; on
/// real decode data the full-episode dump is bit-identical to main.
///
/// OPENCAST_D3_FUZZ_ITERATIONS overrides randomized counts.
/// OPENCAST_SAMPLER_AB_MICROBENCH=1 enables the timing pass.
@Suite("Greedy sampler equivalence", .serialized)
struct GreedySamplerEquivalenceTests {
    private static let realVocabulary = 51864
    private static let truthTolerance: Float = 1e-4
    private static let mlTensorTolerance: Float = 5e-4

    // MARK: Reference (preserved MLTensor temperature-zero path)

    @available(macOS 15, iOS 18, *)
    private func referenceMLTensorSample(logits: MLMultiArray) async -> (token: Int, logprob: Float) {
        let logitsTensor = MLTensor(MLShapedArray<FloatType>(logits)).cast(to: Float.self)
        let softmaxScores = logitsTensor.softmax(alongAxis: -1)
        let nextTokenTensor = logitsTensor.argmax(alongAxis: -1)
        let nextLogprobTensor = softmaxScores.gathering(atIndices: nextTokenTensor, alongAxis: -1).log()
        return (
            token: await nextTokenTensor.toIntArray()[0],
            logprob: await nextLogprobTensor.toFloatArray()[0]
        )
    }

    // MARK: Helpers

    private func makeLogits(_ values: [Float16]) throws -> MLMultiArray {
        let tensor = try MLMultiArray(
            shape: [1, 1, NSNumber(value: values.count)],
            dataType: .float16
        )
        tensor.withUnsafeMutableBytes { pointer, _ in
            let buffer = pointer.bindMemory(to: Float16.self)
            for index in 0..<values.count {
                buffer[index] = values[index]
            }
        }
        return tensor
    }

    private func productionSample(logits: MLMultiArray) async -> (token: Int, logprob: Float) {
        let sampler = GreedyTokenSampler(temperature: 0, eotToken: 50256, decodingOptions: DecodingOptions())
        let result = await sampler.update(tokens: [], logits: logits, logProbs: [])
        return (token: result.tokens.last!, logprob: result.logProbs.last!)
    }

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private func randomValues(_ count: Int, range: ClosedRange<Float>, rng: inout SplitMix64) -> [Float16] {
        (0..<count).map { _ in Float16(Float.random(in: range, using: &rng)) }
    }

    /// Float64 max-shifted log-sum-exp: the accuracy arbiter both fast paths
    /// are measured against.
    private func float64Logprob(_ values: [Float16]) -> Double {
        let doubles = values.map(Double.init)
        guard let maxValue = doubles.max(), maxValue.isFinite else {
            return .nan
        }
        let sum = doubles.reduce(0.0) { $0 + exp($1 - maxValue) }
        return -log(sum)
    }

    /// Returns false (and records an issue) on the first divergence so long
    /// randomized loops stop early instead of flooding output.
    private func expectEquivalent(_ values: [Float16], _ label: String) async throws -> Bool {
        guard #available(macOS 15, iOS 18, *) else { return true }
        let reference = await referenceMLTensorSample(logits: try makeLogits(values))
        let production = await productionSample(logits: try makeLogits(values))

        let tokensMatch = production.token == reference.token
        #expect(tokensMatch, "\(label): token \(production.token) vs \(reference.token)")

        let bothNaN = production.logprob.isNaN && reference.logprob.isNaN
        let bothNegInf = production.logprob == -.infinity && reference.logprob == -.infinity
        let withinCompat = abs(production.logprob - reference.logprob) <= Self.mlTensorTolerance
        let truth = float64Logprob(values)
        let withinTruth = truth.isNaN || abs(production.logprob - Float(truth)) <= Self.truthTolerance
        let logprobOK = bothNaN || bothNegInf || (withinCompat && withinTruth)
        #expect(logprobOK, "\(label): logprob cpu=\(production.logprob) ml=\(reference.logprob) truth=\(truth)")

        return tokensMatch && logprobOK
    }

    // MARK: Gates

    @Test("Randomized tensors: real vocabulary")
    func randomizedRealShape() async throws {
        var rng = SplitMix64(state: 0xD3_0001)
        let iterations = ProcessInfo.processInfo.environment["OPENCAST_D3_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 300
        for iteration in 0..<iterations {
            let values = randomValues(Self.realVocabulary, range: -20...20, rng: &rng)
            guard try await expectEquivalent(values, "real random #\(iteration)") else { return }
        }
    }

    @Test("Randomized tensors: small-shape fuzz")
    func randomizedSmallShape() async throws {
        var rng = SplitMix64(state: 0xD3_0002)
        let iterations = ProcessInfo.processInfo.environment["OPENCAST_D3_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 3000
        for iteration in 0..<iterations {
            let values = randomValues(96, range: -20...20, rng: &rng)
            guard try await expectEquivalent(values, "small random #\(iteration)") else { return }
        }
    }

    @Test("Exact-value ties break to the same index")
    func exactTies() async throws {
        var rng = SplitMix64(state: 0xD3_0003)
        // Identical Float16 maxima at scattered positions, including
        // adjacent pairs, first/last element, and many-way ties.
        for round in 0..<200 {
            var values = randomValues(96, range: -14 ... -6, rng: &rng)
            let tieValue = Float16(Float.random(in: -2...2, using: &rng))
            let tieCount = 2 + round % 5
            var indexes = Set<Int>()
            while indexes.count < tieCount {
                indexes.insert(Int.random(in: 0..<96, using: &rng))
            }
            for index in indexes { values[index] = tieValue }
            guard try await expectEquivalent(values, "tie #\(round) at \(indexes.sorted())") else { return }
        }

        var values = [Float16](repeating: -10, count: 96)
        values[0] = 3; values[95] = 3
        guard try await expectEquivalent(values, "tie first/last") else { return }
        values = [Float16](repeating: 5, count: 96)
        _ = try await expectEquivalent(values, "all equal")
    }

    @Test("Suppressed ranges (filter output patterns)")
    func suppressedRanges() async throws {
        var rng = SplitMix64(state: 0xD3_0004)
        let time = 64

        // Timestamp block suppressed (pair rule).
        var values = randomValues(96, range: -10...10, rng: &rng)
        for index in time..<96 { values[index] = -.infinity }
        guard try await expectEquivalent(values, "T suppressed") else { return }

        // Text block suppressed (sample-timestamp decision).
        values = randomValues(96, range: -10...10, rng: &rng)
        for index in 0..<time { values[index] = -.infinity }
        guard try await expectEquivalent(values, "text suppressed") else { return }

        // Everything but one token suppressed (EOT-only shape).
        values = [Float16](repeating: -.infinity, count: 96)
        values[42] = -0.5
        guard try await expectEquivalent(values, "single survivor") else { return }

        // Scattered suppression.
        for round in 0..<50 {
            values = randomValues(96, range: -10...10, rng: &rng)
            for index in values.indices where Int.random(in: 0..<3, using: &rng) == 0 {
                values[index] = -.infinity
            }
            guard try await expectEquivalent(values, "scattered -inf #\(round)") else { return }
        }
    }

    @Test("Degenerate values: ±inf, NaN, saturation")
    func degenerateValues() async throws {
        var rng = SplitMix64(state: 0xD3_0005)

        var values = randomValues(96, range: -10...10, rng: &rng)
        values[10] = .infinity
        guard try await expectEquivalent(values, "+inf single") else { return }

        // NaN logits are OUT OF the equivalence contract: they are
        // unreachable from real decode inputs (model outputs are f16 values;
        // filters only write -inf), vDSP_maxvi's NaN handling is
        // lane-dependent and unstable across launches, and MLTensor ignores
        // NaN — no deterministic equivalence exists to gate on. Assert only
        // that the production path returns without trapping.
        values = randomValues(96, range: -10...10, rng: &rng)
        values[10] = .nan
        _ = await productionSample(logits: try makeLogits(values))

        values = [Float16](repeating: -.infinity, count: 96)
        guard try await expectEquivalent(values, "all -inf") else { return }

        values = randomValues(96, range: -60000...60000, rng: &rng)
        guard try await expectEquivalent(values, "saturation range") else { return }

        values = randomValues(96, range: -10...10, rng: &rng)
        values[5] = Float16.greatestFiniteMagnitude
        values[6] = Float16.greatestFiniteMagnitude
        _ = try await expectEquivalent(values, "saturated tie")
    }

    @Test("Two-band near-flat tensors (worst known log-prob divergence)")
    func twoBandNearFlat() async throws {
        // Adversarial family found by the D3 verification pass: a winner
        // barely above a huge near-flat band maximizes softmax reduction
        // error. MLTensor lands ~2.5e-4 from float64 truth here; the CPU
        // path stays within ~5e-5. Gates both declared tolerances.
        var rng = SplitMix64(state: 0xD3_0010)
        for round in 0..<60 {
            let count = Self.realVocabulary
            var values = [Float16](repeating: Float16(-3.5), count: count)
            let bandWidth = [1000, 5000, 10247, 25000, 51863][round % 5]
            let bandValue = Float16(Float.random(in: -0.2 ... -0.05, using: &rng))
            for index in 1...bandWidth {
                values[index] = bandValue
            }
            values[0] = 0
            guard try await expectEquivalent(values, "two-band #\(round) width=\(bandWidth)") else { return }
        }
    }

    @Test("Log-prob accuracy near fallback thresholds")
    func nearFallbackThresholds() async throws {
        var rng = SplitMix64(state: 0xD3_0006)
        // Engineer winner log-probs to land right at the decision thresholds
        // (avgLogProb −1.0, firstTokenLogProb −1.5): the winner's softmax
        // probability is e^t against mass soaked by a flat background.
        for target in [Float(-1.0), Float(-1.5)] {
            for round in 0..<100 {
                let count = 96
                // p(winner) = e^target → background mass = 1 - e^target
                // spread over count-1 tokens: x_bg = log((1-e^t)/(n-1)) + x_w.
                let winner = Float.random(in: -1...1, using: &rng)
                let background = logf((1 - expf(target)) / Float(count - 1)) + winner
                var values = [Float16](repeating: Float16(background), count: count)
                values[round % count] = Float16(winner)
                guard try await expectEquivalent(values, "threshold \(target) #\(round)") else { return }
            }
        }
    }

    @Test(
        "Opt-in: per-call timing, CPU vs MLTensor",
        .enabled(if: ProcessInfo.processInfo.environment["OPENCAST_SAMPLER_AB_MICROBENCH"] == "1")
    )
    func timingPass() async throws {
        guard #available(macOS 15, iOS 18, *) else { return }
        var rng = SplitMix64(state: 0xD3_0007)
        let values = randomValues(Self.realVocabulary, range: -20...20, rng: &rng)
        let logits = try makeLogits(values)
        let clock = ContinuousClock()
        var maxDelta: Float = 0

        for (label, warmups, repeats) in [("warmup", 20, 0), ("measure", 0, 200)] {
            _ = label
            for _ in 0..<warmups {
                _ = await productionSample(logits: logits)
                _ = await referenceMLTensorSample(logits: logits)
            }
            guard repeats > 0 else { continue }

            var start = clock.now
            var cpuToken = 0
            for _ in 0..<repeats {
                cpuToken &+= (await productionSample(logits: logits)).token
            }
            let cpuDuration = start.duration(to: clock.now)

            start = clock.now
            var tensorToken = 0
            for _ in 0..<repeats {
                tensorToken &+= (await referenceMLTensorSample(logits: logits)).token
            }
            let tensorDuration = start.duration(to: clock.now)

            let production = await productionSample(logits: logits)
            let reference = await referenceMLTensorSample(logits: logits)
            maxDelta = max(maxDelta, abs(production.logprob - reference.logprob))

            func micros(_ duration: Duration) -> Double {
                (Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 1e6 / Double(repeats)
            }
            print("SAMPLER_AB cpu_us_per_call=\(String(format: "%.1f", micros(cpuDuration))) mltensor_us_per_call=\(String(format: "%.1f", micros(tensorDuration))) tokensAgree=\(cpuToken == tensorToken) logprobMaxDelta=\(maxDelta)")
        }
    }
}
