//  For licensing see accompanying LICENSE.md file.
//  Copyright © 2024 Argmax, Inc. All rights reserved.

import Accelerate
import CoreML
import Foundation

public protocol LogitsFiltering {
    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray
}

open class SuppressTokensFilter: LogitsFiltering {
    let suppressTokens: [Int]
    private let suppressTokenIndexes: [[Int]]

    public init(suppressTokens: [Int]) {
        self.suppressTokens = suppressTokens
        self.suppressTokenIndexes = suppressTokens.map { [0, 0, $0] }
    }

    public func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        logits.fill(indexes: suppressTokenIndexes, with: -FloatType.infinity)
        return logits
    }
}

open class SuppressBlankFilter: LogitsFiltering {
    let specialTokens: SpecialTokens
    let sampleBegin: Int
    private let suppressTokenIndexes: [[Int]]

    public init(
        specialTokens: SpecialTokens,
        sampleBegin: Int
    ) {
        self.specialTokens = specialTokens
        self.sampleBegin = sampleBegin
        self.suppressTokenIndexes = [
            [0, 0, specialTokens.whitespaceToken],
            [0, 0, specialTokens.endToken],
        ]
    }

    public func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        guard tokens.count == sampleBegin else {
            return logits
        }
        logits.fill(indexes: suppressTokenIndexes, with: -FloatType.infinity)
        return logits
    }
}

/// Implementation based on https://github.com/openai/whisper/blob/master/whisper/decoding.py#L441
open class TimestampRulesFilter: LogitsFiltering {
    let specialTokens: SpecialTokens
    let sampleBegin: Int
    let maxInitialTimestampIndex: Int?
    let isModelMultilingual: Bool

    public init(
        specialTokens: SpecialTokens,
        sampleBegin: Int,
        maxInitialTimestampIndex: Int?,
        isModelMultilingual: Bool
    ) {
        self.specialTokens = specialTokens
        self.sampleBegin = sampleBegin
        self.maxInitialTimestampIndex = maxInitialTimestampIndex
        self.isModelMultilingual = isModelMultilingual
    }

    public func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        guard let sampleBegin = sampleBegin(for: tokens),
              sampleBegin <= tokens.count
        else {
            // Early return if we are still prefilling the prompt
            return logits
        }

        // suppress <|notimestamps|> which is handled by `withoutTimestamps`
        logits.fill(indexes: [[0, 0, specialTokens.noTimestampsToken]], with: -FloatType.infinity)

        if tokens.count > sampleBegin {
            // timestamps have to appear in pairs, except directly before EOT; mask logits accordingly
            let sampledTokens = tokens[sampleBegin...]
            let lastWasTimestamp = sampledTokens.count >= 1 && sampledTokens.last! >= specialTokens.timeTokenBegin
            let penultimateWasTimestamp = sampledTokens.count < 2 || sampledTokens.dropLast().last! >= specialTokens.timeTokenBegin
            if lastWasTimestamp {
                if penultimateWasTimestamp {
                    // has to be non-timestamp
                    logits.fillLastDimension(indexes: specialTokens.timeTokenBegin..<logits.count, with: -FloatType.infinity)
                } else {
                    // cannot be normal text tokens
                    logits.fillLastDimension(indexes: 0..<specialTokens.endToken, with: -FloatType.infinity)
                }
            }

            let timestamps = sampledTokens.filter { $0 >= specialTokens.timeTokenBegin }
            if let lastTimestamp = timestamps.last {
                // timestamps shouldn't decrease; forbid timestamp tokens smaller than the last
                // also force each segment to have a nonzero length, to prevent infinite looping
                let timestampLast =
                    if lastWasTimestamp && !penultimateWasTimestamp {
                        lastTimestamp
                    } else {
                        lastTimestamp + 1
                    }
                logits.fillLastDimension(indexes: specialTokens.timeTokenBegin..<timestampLast, with: -FloatType.infinity)
            }
        }

        // TODO: Allow model to predict initial timestamp
        // Currently initial timestamp is forced to <|0.00|> every time
//       if tokens.count == sampleBegin {
//           // suppress generating non-timestamp tokens at the beginning
//           logits.fillLastDimension(indexes: 0..<specialTokens.timeTokenBegin, with: -FloatType.infinity)
//           if let maxInitialTimestampIndex {
//               // apply the `maxInitialTimestamp` option
//               let lastAllowed = specialTokens.timeTokenBegin + maxInitialTimestampIndex + 1
//               logits.fillLastDimension(indexes: lastAllowed..<logits.count, with: -FloatType.infinity)
//           }
//       }

        // if sum of probability over timestamps is above any other token, sample timestamp
        if sumOfProbabilityOverTimestampsIsAboveAnyOtherToken(logits: logits, timeTokenBegin: specialTokens.timeTokenBegin) {
            logits.fillLastDimension(indexes: 0..<specialTokens.timeTokenBegin, with: -FloatType.infinity)
        }
        return logits
    }

    private func sampleBegin(for tokens: [Int]) -> Int? {
        if isModelMultilingual {
            // NOTE: for multilingual model we don't want to suppress "<|transcribe|>" or "<|translate|>" tokens
            if let taskTokenIndex = tokens.prefix(3).firstIndex(where: { $0 == specialTokens.transcribeToken || $0 == specialTokens.translateToken }) {
                return max(taskTokenIndex + 1, sampleBegin)
            } else {
                return nil
            }
        } else {
            return sampleBegin
        }
    }

    private func sumOfProbabilityOverTimestampsIsAboveAnyOtherToken(logits: MLMultiArray, timeTokenBegin: Int) -> Bool {
        // OpenCast fork (whisper-perf D2): certify-or-fallback. The upstream
        // full-vocabulary log-softmax normalizer cancels algebraically in
        //   logsumexp(logprobs[T...]) > max(logprobs[..<T])
        // so raw-logit reductions give the same decision — except within a
        // few Float16 ULP of the boundary, where the two rounding pipelines
        // can disagree (and on +inf/NaN, where their semantics differ). The
        // fast path therefore certifies its answer only when the margin
        // |lse(T) − max(text)| clears a conservative scale-aware epsilon
        // (32 ULP16; worst observed disagreement is ~0.4 ULP16) and the
        // tensor holds no +inf/NaN and no magnitude ≥ 512. Anything
        // uncertified runs the original log-softmax pipeline unchanged.
        // Decision equivalence is gated by
        // TimestampFilterDecisionEquivalenceTests.
        if let certified = certifiedRawLogitDecision(logits: logits, timeTokenBegin: timeTokenBegin) {
            return certified
        }
        return upstreamLogSoftmaxDecision(logits: logits, timeTokenBegin: timeTokenBegin)
    }

    private func certifiedRawLogitDecision(logits: MLMultiArray, timeTokenBegin: Int) -> Bool? {
        let timeTokenBeginOffset = logits.linearOffset(for: [0, 0, timeTokenBegin])
        let totalCount = logits.count
        let timeTokenCount = totalCount - timeTokenBeginOffset
        guard timeTokenCount > 0, timeTokenBeginOffset > 0 else { return nil }

        let basePointer = logits.dataPointer

        // Any +inf or NaN anywhere → uncertifiable (-inf is fine; suppressed
        // ranges are the common case). Bit test: exponent all-ones and not
        // exactly the -inf pattern.
        var anyUncertifiable = false
        let bits = basePointer.assumingMemoryBound(to: UInt16.self)
        var index = 0
        let expMask = SIMD16<UInt16>(repeating: 0x7C00)
        let negInfPattern = SIMD16<UInt16>(repeating: 0xFC00)
        var flagged = SIMD16<UInt16>.zero
        let one = SIMD16<UInt16>(repeating: 1)
        while index + 16 <= totalCount {
            let vector = UnsafeRawPointer(bits + index).loadUnaligned(as: SIMD16<UInt16>.self)
            let special = (vector & expMask) .== expMask
            let isNegInf = vector .== negInfPattern
            flagged |= one.replacing(with: SIMD16<UInt16>.zero, where: .!(special .& .!isNegInf))
            index += 16
        }
        anyUncertifiable = flagged.max() != 0
        while index < totalCount, !anyUncertifiable {
            let value = bits[index]
            if (value & 0x7C00) == 0x7C00, value != 0xFC00 { anyUncertifiable = true }
            index += 1
        }
        if anyUncertifiable { return nil }

        func rawReduction(_ function: BNNS.ReductionFunction, offset: Int, count: Int) -> FloatType? {
            guard let input = BNNSNDArrayDescriptor(
                data: UnsafeMutableRawBufferPointer(
                    start: basePointer.advanced(by: offset * MemoryLayout<FloatType>.stride),
                    count: count * MemoryLayout<FloatType>.stride
                ),
                scalarType: FloatType.self,
                shape: .vector(count, stride: 1)
            ) else { return nil }
            let output = BNNSNDArrayDescriptor.allocateUninitialized(
                scalarType: FloatType.self,
                shape: .vector(1, stride: 1)
            )
            defer { output.deallocate() }
            do {
                try BNNS.applyReduction(function, input: input, output: output, weights: nil)
            } catch {
                return nil
            }
            return output.makeArray(of: FloatType.self)?.first
        }

        guard let maxText16 = rawReduction(.max, offset: 0, count: timeTokenBeginOffset),
              let lseTime16 = rawReduction(.logSumExp, offset: timeTokenBeginOffset, count: timeTokenCount)
        else { return nil }

        let maxText = Float(maxText16)
        let lseTime = Float(lseTime16)
        guard maxText.isFinite, lseTime.isFinite,
              abs(maxText) < 512, abs(lseTime) < 512 else { return nil }

        // Scale-aware epsilon: one Float16 ULP at the largest magnitude the
        // upstream pipeline's intermediates can reach, times a 32x guard.
        func ulp16(atMagnitude magnitude: Float) -> Float {
            let clamped = max(magnitude, 6.1035156e-5)
            return exp2f(floorf(log2f(clamped)) - 10)
        }
        let logVocab = logf(Float(totalCount))
        let logTime = logf(Float(timeTokenCount))
        let scale = max(
            max(abs(lseTime - max(maxText, lseTime)) + logVocab + logTime,
                abs(maxText - max(maxText, lseTime)) + logVocab),
            max(abs(lseTime), max(abs(maxText), 1))
        )
        let epsilon = 32 * ulp16(atMagnitude: scale)
        let margin = lseTime - maxText
        return abs(margin) > epsilon ? margin > 0 : nil
    }

    private func upstreamLogSoftmaxDecision(logits: MLMultiArray, timeTokenBegin: Int) -> Bool {
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
            Logging.error("Cannot create `logprobsInputDescriptor`")
            return false
        }

        let logprobs = BNNSNDArrayDescriptor.allocateUninitialized(
            scalarType: FloatType.self,
            shape: .vector(logits.count, stride: 1)
        )
        defer { logprobs.deallocate() }

        do {
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
                Logging.error("Cannot create `logSumExpInputDescriptor`")
                return false
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
                Logging.error("Cannot create `maxTextTokenLogProbInputDescriptor`")
                return false
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
                Logging.error("Cannot create logProb arrays")
                return false
            }
            return timestampLogProbValue > maxTextTokenLogProbValue
        } catch {
            Logging.error("TimestampRulesFilter error: \(error)")
            return false
        }
    }
}

open class LanguageLogitsFilter: LogitsFiltering {
    let allLanguageTokens: Set<Int>
    let logitsDim: Int
    let sampleBegin: Int
    let nonLanguageTokenIndexes: [[Int]]

    public init(allLanguageTokens: Set<Int>, logitsDim: Int, sampleBegin: Int) {
        self.allLanguageTokens = allLanguageTokens
        self.logitsDim = logitsDim
        self.sampleBegin = sampleBegin
        self.nonLanguageTokenIndexes = LanguageLogitsFilter.getNonLanguageTokenIndexes(logitsDim: self.logitsDim, allLanguageTokens: self.allLanguageTokens)
    }

    /// Retain the logits that correspond to language tokens and suppress non-language tokens
    public func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        guard tokens.count >= sampleBegin else {
            return logits
        }
        logits.fill(indexes: nonLanguageTokenIndexes, with: -FloatType.infinity)
        return logits
    }

    private static func getNonLanguageTokenIndexes(logitsDim: Int, allLanguageTokens: Set<Int>) -> [[Int]] {
        var indexes: [[Int]] = []
        for i in 0..<logitsDim {
            if !allLanguageTokens.contains(i) {
                indexes.append([0, 0, i])
            }
        }
        return indexes
    }
}
