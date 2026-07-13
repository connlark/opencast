import Accelerate
import CoreML
import Foundation
import Testing
@preconcurrency import WhisperKit

/// D2 gate (whisper-perf pass 2): the raw-logit timestamp filter must
/// produce bit-identical filtered tensors — and therefore exactly the same
/// Boolean sample-timestamp decision — as the upstream full-vocabulary
/// log-softmax implementation, on randomized Float16 tensors plus
/// adversarial categories (±inf, NaN, fully suppressed ranges, near ties at
/// Float16 resolution, boundary tokens, and prompt-prefix contexts).
/// Algebraic equivalence is not evidence; Float16 decision equivalence is.
///
/// The value-category tests run in a text-only token context where the only
/// pre-decision mutation is the <|notimestamps|> suppression, so crafted
/// adversarial values reach the decision untouched. Context interactions are
/// covered separately by `fullFilterOutputsAcrossContexts`.
///
/// OPENCAST_D2_FUZZ_ITERATIONS overrides the randomized case counts.
@Suite("Timestamp filter decision equivalence")
struct TimestampFilterDecisionEquivalenceTests {
    // MARK: Upstream reference (preserved implementation)

    /// Bit-for-bit copy of the upstream sum-of-probability decision.
    private func referenceDecision(logits: MLMultiArray, timeTokenBegin: Int) throws -> Bool {
        let timeTokenBeginOffset = logits.linearOffset(for: [0, 0, timeTokenBegin])

        let logprobsInputPointer = UnsafeMutableRawBufferPointer(
            start: logits.dataPointer,
            count: logits.count * MemoryLayout<FloatType>.stride
        )

        guard let logprobsInputDescriptor = BNNSNDArrayDescriptor(
            data: logprobsInputPointer,
            scalarType: FloatType.self,
            shape: .vector(logits.count, stride: 1)
        ) else {
            throw WhisperError.transcriptionFailed("logprobsInputDescriptor")
        }

        let logprobs = BNNSNDArrayDescriptor.allocateUninitialized(
            scalarType: FloatType.self,
            shape: .vector(logits.count, stride: 1)
        )
        defer { logprobs.deallocate() }

        try BNNS.applyActivation(
            activation: BNNS.ActivationFunction.logSoftmax,
            input: logprobsInputDescriptor,
            output: logprobs,
            batchSize: 1
        )

        let timeTokenCount = logits.count - timeTokenBeginOffset
        let noTimeTokenCount = timeTokenBeginOffset
        let logSumExpInputPointer = UnsafeMutableRawBufferPointer(
            start: logprobs.data!.advanced(by: timeTokenBeginOffset * MemoryLayout<FloatType>.stride),
            count: timeTokenCount * MemoryLayout<FloatType>.stride
        )

        guard let logSumExpInputDescriptor = BNNSNDArrayDescriptor(
            data: logSumExpInputPointer,
            scalarType: FloatType.self,
            shape: .vector(timeTokenCount, stride: 1)
        ) else {
            throw WhisperError.transcriptionFailed("logSumExpInputDescriptor")
        }

        let timestampLogProb = BNNSNDArrayDescriptor.allocateUninitialized(
            scalarType: FloatType.self,
            shape: .vector(1, stride: 1)
        )
        defer { timestampLogProb.deallocate() }

        try BNNS.applyReduction(
            .logSumExp,
            input: logSumExpInputDescriptor,
            output: timestampLogProb,
            weights: nil
        )

        let maxTextTokenLogProbInputPointer = UnsafeMutableRawBufferPointer(
            start: logprobs.data,
            count: noTimeTokenCount * MemoryLayout<FloatType>.stride
        )

        guard let maxTextTokenLogProbInputDescriptor = BNNSNDArrayDescriptor(
            data: maxTextTokenLogProbInputPointer,
            scalarType: FloatType.self,
            shape: .vector(noTimeTokenCount, stride: 1)
        ) else {
            throw WhisperError.transcriptionFailed("maxTextTokenLogProbInputDescriptor")
        }

        let maxTextTokenLogProb = BNNSNDArrayDescriptor.allocateUninitialized(
            scalarType: FloatType.self,
            shape: .vector(1, stride: 1)
        )
        defer { maxTextTokenLogProb.deallocate() }

        try BNNS.applyReduction(
            .max,
            input: maxTextTokenLogProbInputDescriptor,
            output: maxTextTokenLogProb,
            weights: nil
        )

        guard let timestampLogProbValue = timestampLogProb.makeArray(of: FloatType.self)?.first,
              let maxTextTokenLogProbValue = maxTextTokenLogProb.makeArray(of: FloatType.self)?.first
        else {
            throw WhisperError.transcriptionFailed("logProb arrays")
        }
        return timestampLogProbValue > maxTextTokenLogProbValue
    }

    /// Upstream filterLogits, reproduced around the reference decision.
    private func referenceFilter(
        _ logits: MLMultiArray,
        tokenHistory: [Int],
        specialTokens tokens: SpecialTokens,
        sampleBegin: Int
    ) throws -> MLMultiArray {
        guard sampleBegin <= tokenHistory.count else { return logits }
        let time = tokens.timeTokenBegin
        logits.fill(indexes: [[0, 0, NSNumber(value: tokens.noTimestampsToken)]], with: -FloatType.infinity)
        if tokenHistory.count > sampleBegin {
            let sampled = tokenHistory[sampleBegin...]
            let lastWasTimestamp = sampled.count >= 1 && sampled.last! >= time
            let penultimateWasTimestamp = sampled.count < 2 || sampled.dropLast().last! >= time
            if lastWasTimestamp {
                if penultimateWasTimestamp {
                    logits.fillLastDimension(indexes: time..<logits.count, with: -FloatType.infinity)
                } else {
                    logits.fillLastDimension(indexes: 0..<tokens.endToken, with: -FloatType.infinity)
                }
            }
            let timestamps = sampled.filter { $0 >= time }
            if let lastTimestamp = timestamps.last {
                let timestampLast = (lastWasTimestamp && !penultimateWasTimestamp) ? lastTimestamp : lastTimestamp + 1
                logits.fillLastDimension(indexes: time..<timestampLast, with: -FloatType.infinity)
            }
        }
        if try referenceDecision(logits: logits, timeTokenBegin: time) {
            logits.fillLastDimension(indexes: 0..<time, with: -FloatType.infinity)
        }
        return logits
    }

    // MARK: Case construction

    private struct Shape {
        var vocabulary: Int
        var timeTokenBegin: Int

        // tiny.en decoder dimensions.
        static let real = Shape(vocabulary: 51864, timeTokenBegin: 50363)
        static let small = Shape(vocabulary: 96, timeTokenBegin: 64)
    }

    private func specialTokens(for shape: Shape) -> SpecialTokens {
        SpecialTokens(
            endToken: max(1, shape.timeTokenBegin / 2),
            englishToken: 2,
            noSpeechToken: 3,
            noTimestampsToken: shape.timeTokenBegin - 1,
            specialTokenBegin: max(1, shape.timeTokenBegin / 2),
            startOfPreviousToken: 4,
            startOfTranscriptToken: 5,
            timeTokenBegin: shape.timeTokenBegin,
            transcribeToken: 6,
            translateToken: 7,
            whitespaceToken: 8
        )
    }

    private func makeLogits(_ values: [Float16], shape: Shape) throws -> MLMultiArray {
        precondition(values.count == shape.vocabulary)
        let tensor = try MLMultiArray(
            shape: [1, 1, NSNumber(value: shape.vocabulary)],
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

    private func randomValues(_ shape: Shape, range: ClosedRange<Float>, rng: inout SplitMix64) -> [Float16] {
        (0..<shape.vocabulary).map { _ in Float16(Float.random(in: range, using: &rng)) }
    }

    /// Text-only history: the only pre-decision mutation is the
    /// <|notimestamps|> fill, so crafted values reach the decision untouched.
    private let textOnlyHistory = [0, 0, 0, 1]
    private let sampleBegin = 3

    private func expectEquivalent(
        _ values: [Float16],
        shape: Shape,
        _ label: String,
        tokenHistory: [Int]? = nil
    ) throws -> Bool {
        let tokens = specialTokens(for: shape)
        let history = tokenHistory ?? textOnlyHistory
        let filter = TimestampRulesFilter(
            specialTokens: tokens,
            sampleBegin: sampleBegin,
            maxInitialTimestampIndex: nil,
            isModelMultilingual: false
        )

        let productionTensor = try makeLogits(values, shape: shape)
        let referenceTensor = try makeLogits(values, shape: shape)

        _ = filter.filterLogits(productionTensor, withTokens: history)
        _ = try referenceFilter(referenceTensor, tokenHistory: history, specialTokens: tokens, sampleBegin: sampleBegin)

        let identical = productionTensor.dataEquals(referenceTensor)
        #expect(identical, "\(label): filtered tensors differ")
        return identical
    }

    // MARK: Suite

    @Test("Randomized tensors: real shape")
    func randomizedRealShape() throws {
        var rng = SplitMix64(state: 0xD2_0001)
        let iterations = ProcessInfo.processInfo.environment["OPENCAST_D2_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 200
        for iteration in 0..<iterations {
            let values = randomValues(.real, range: -20...20, rng: &rng)
            guard try expectEquivalent(values, shape: .real, "real random #\(iteration)") else { return }
        }
    }

    @Test("Randomized tensors: small-shape fuzz")
    func randomizedSmallShape() throws {
        var rng = SplitMix64(state: 0xD2_0002)
        let iterations = ProcessInfo.processInfo.environment["OPENCAST_D2_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 2000
        for iteration in 0..<iterations {
            let values = randomValues(.small, range: -20...20, rng: &rng)
            guard try expectEquivalent(values, shape: .small, "small random #\(iteration)") else { return }
        }
    }

    @Test("Near ties at Float16 resolution")
    func nearTies() throws {
        var rng = SplitMix64(state: 0xD2_0003)
        let shape = Shape.small
        // All timestamp mass on one token; text max engineered to sit within
        // a few ULP of it on both sides, including exact equality.
        for iteration in 0..<400 {
            var values = randomValues(shape, range: -14 ... -6, rng: &rng)
            let anchor = Float16(Float.random(in: -4...4, using: &rng))
            for index in shape.timeTokenBegin..<shape.vocabulary {
                values[index] = -Float16.infinity
            }
            values[shape.timeTokenBegin + 1] = anchor
            var textPeak = anchor
            let ulpSteps = iteration % 9 - 4 // -4...4 ULP
            if ulpSteps > 0 {
                for _ in 0..<ulpSteps { textPeak = textPeak.nextUp }
            } else if ulpSteps < 0 {
                for _ in 0..<(-ulpSteps) { textPeak = textPeak.nextDown }
            }
            values[1] = textPeak
            guard try expectEquivalent(values, shape: shape, "near tie #\(iteration) ulp=\(ulpSteps)") else { return }
        }
    }

    @Test("Two-sided timestamp mass near ties")
    func nearTiesSplitMass() throws {
        var rng = SplitMix64(state: 0xD2_0009)
        let shape = Shape.small
        // lse over several comparable timestamp logits, engineered close to
        // the text peak: lse(T) ≈ anchor + log(k) for k equal entries.
        for iteration in 0..<300 {
            var values = randomValues(shape, range: -16 ... -8, rng: &rng)
            let anchor = Float16(Float.random(in: -3...3, using: &rng))
            let k = 1 + iteration % 6
            for index in shape.timeTokenBegin..<shape.vocabulary {
                values[index] = -Float16.infinity
            }
            for offset in 0..<k {
                values[shape.timeTokenBegin + 1 + offset] = anchor
            }
            let target = Float(anchor) + logf(Float(k))
            var textPeak = Float16(target)
            let ulpSteps = iteration % 7 - 3
            if ulpSteps > 0 {
                for _ in 0..<ulpSteps { textPeak = textPeak.nextUp }
            } else if ulpSteps < 0 {
                for _ in 0..<(-ulpSteps) { textPeak = textPeak.nextDown }
            }
            values[1] = textPeak
            guard try expectEquivalent(values, shape: shape, "split-mass tie #\(iteration) k=\(k) ulp=\(ulpSteps)") else { return }
        }
    }

    @Test("Suppressed ranges and infinities")
    func suppressedRangesAndInfinities() throws {
        var rng = SplitMix64(state: 0xD2_0004)
        let shape = Shape.small

        // Fully suppressed timestamp range (pair-rule fill pattern).
        var values = randomValues(shape, range: -10...10, rng: &rng)
        for index in shape.timeTokenBegin..<shape.vocabulary { values[index] = -Float16.infinity }
        guard try expectEquivalent(values, shape: shape, "T fully -inf") else { return }

        // Fully suppressed text range.
        values = randomValues(shape, range: -10...10, rng: &rng)
        for index in 0..<shape.timeTokenBegin { values[index] = -Float16.infinity }
        guard try expectEquivalent(values, shape: shape, "text fully -inf") else { return }

        // Everything suppressed.
        values = Array(repeating: -Float16.infinity, count: shape.vocabulary)
        guard try expectEquivalent(values, shape: shape, "all -inf") else { return }

        // Scattered -inf.
        for round in 0..<50 {
            values = randomValues(shape, range: -10...10, rng: &rng)
            for index in values.indices where Int.random(in: 0..<3, using: &rng) == 0 {
                values[index] = -Float16.infinity
            }
            guard try expectEquivalent(values, shape: shape, "scattered -inf #\(round)") else { return }
        }

        // +inf in the timestamp range, in the text range, and in both.
        values = randomValues(shape, range: -10...10, rng: &rng)
        values[shape.timeTokenBegin + 2] = .infinity
        guard try expectEquivalent(values, shape: shape, "+inf in T") else { return }

        values = randomValues(shape, range: -10...10, rng: &rng)
        values[2] = .infinity
        guard try expectEquivalent(values, shape: shape, "+inf in text") else { return }

        values = randomValues(shape, range: -10...10, rng: &rng)
        values[2] = .infinity
        values[shape.timeTokenBegin + 2] = .infinity
        guard try expectEquivalent(values, shape: shape, "+inf in both") else { return }
    }

    @Test("NaN propagation")
    func nanPropagation() throws {
        var rng = SplitMix64(state: 0xD2_0005)
        let shape = Shape.small

        var values = randomValues(shape, range: -10...10, rng: &rng)
        values[shape.timeTokenBegin + 1] = .nan
        guard try expectEquivalent(values, shape: shape, "NaN in T") else { return }

        values = randomValues(shape, range: -10...10, rng: &rng)
        values[3] = .nan
        guard try expectEquivalent(values, shape: shape, "NaN in text") else { return }

        values = randomValues(shape, range: -10...10, rng: &rng)
        values[3] = .nan
        values[shape.timeTokenBegin + 1] = .nan
        _ = try expectEquivalent(values, shape: shape, "NaN in both")
    }

    @Test("Large magnitudes near Float16 limits")
    func largeMagnitudes() throws {
        var rng = SplitMix64(state: 0xD2_0006)
        let shape = Shape.small
        for round in 0..<100 {
            let values = randomValues(shape, range: -65000...65000, rng: &rng)
            guard try expectEquivalent(values, shape: shape, "large magnitude #\(round)") else { return }
        }
        // Saturated maxima on both sides.
        var values = randomValues(shape, range: -10...10, rng: &rng)
        values[1] = Float16.greatestFiniteMagnitude
        values[shape.timeTokenBegin + 1] = Float16.greatestFiniteMagnitude
        _ = try expectEquivalent(values, shape: shape, "both saturated")
    }

    @Test("Boundary token placement")
    func boundaryTokens() throws {
        var rng = SplitMix64(state: 0xD2_0007)
        let shape = Shape.small
        // Peak exactly at timeTokenBegin, its neighbors, first, and last index.
        for peakIndex in [0, shape.timeTokenBegin - 2, shape.timeTokenBegin, shape.vocabulary - 1] {
            var values = randomValues(shape, range: -14 ... -6, rng: &rng)
            values[peakIndex] = 5
            guard try expectEquivalent(values, shape: shape, "peak at \(peakIndex)") else { return }
        }
    }

    @Test("Full filterLogits output across token contexts")
    func fullFilterOutputsAcrossContexts() throws {
        var rng = SplitMix64(state: 0xD2_0008)
        let shape = Shape.real
        let time = shape.timeTokenBegin

        // Prompt-prefix early return, boundary at sampleBegin, and every
        // pair-rule branch (which change what the decision sees and what the
        // final fill can touch).
        let contexts: [(String, [Int])] = [
            ("prefill prompt (early return)", [0, 0]),
            ("at sampleBegin", [0, 0, 0]),
            ("text only", [0, 0, 0, 1, 2, 3]),
            ("last was timestamp, pair open", [0, 0, 0, 1, time + 5]),
            ("timestamp pair closed", [0, 0, 0, time + 5, time + 5, 7]),
            ("double timestamp (pair rule)", [0, 0, 0, 7, time + 5, time + 6]),
            ("timestamp history, text tail", [0, 0, 0, time + 3, time + 4, 9, 11]),
        ]

        for (label, tokenHistory) in contexts {
            for round in 0..<12 {
                let values = randomValues(shape, range: -18...18, rng: &rng)
                guard try expectEquivalent(values, shape: shape, "\(label) round \(round)", tokenHistory: tokenHistory) else { return }
            }
        }
    }
}

private extension MLMultiArray {
    func dataEquals(_ other: MLMultiArray) -> Bool {
        let byteCount = count * MemoryLayout<Float16>.stride
        return memcmp(dataPointer, other.dataPointer, byteCount) == 0
    }
}
