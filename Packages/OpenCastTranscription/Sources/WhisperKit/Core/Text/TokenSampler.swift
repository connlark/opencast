//  For licensing see accompanying LICENSE.md file.
//  Copyright © 2024 Argmax, Inc. All rights reserved.

import Accelerate
import CoreML
import Foundation

public protocol TokenSampling {
    func update(tokens: [Int], logits: MLMultiArray, logProbs: [Float]) async -> SamplingResult
    func finalize(tokens: [Int], logProbs: [Float]) -> SamplingResult
}

public struct SamplingResult: Sendable {
    public var tokens: [Int]
    public var logProbs: [Float]
    public var completed: Bool

    public init(
        tokens: [Int],
        logProbs: [Float],
        completed: Bool
    ) {
        self.tokens = tokens
        self.logProbs = logProbs
        self.completed = completed
    }
}

/// OpenCast fork (whisper-perf F): seedable generator for deterministic
/// fallback sampling. One instance per sampler — no global state, no
/// cross-window coupling.
public struct SplitMix64RandomNumberGenerator: RandomNumberGenerator {
    public var state: UInt64

    public init(state: UInt64) {
        self.state = state
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

open class GreedyTokenSampler: TokenSampling {
    public var temperature: FloatType
    public var eotToken: Int
    public var decodingOptions: DecodingOptions
    // OpenCast fork (whisper-perf F): when set, temperature > 0 draws come
    // from this generator instead of the process-global RNG, making fallback
    // retries reproducible. Temperature-zero sampling never draws.
    private var seededGenerator: SplitMix64RandomNumberGenerator?

    public init(temperature: FloatType, eotToken: Int, decodingOptions: DecodingOptions, fallbackSeed: UInt64? = nil) {
        self.temperature = temperature
        self.eotToken = eotToken
        self.decodingOptions = decodingOptions
        seededGenerator = fallbackSeed.map { SplitMix64RandomNumberGenerator(state: $0) }
    }

    private func nextRandom(in range: Range<Float>) -> Float {
        if var generator = seededGenerator {
            let value = Float.random(in: range, using: &generator)
            seededGenerator = generator
            return value
        }
        return Float.random(in: range)
    }

    /// OpenCast fork (whisper-perf D3): temperature-zero greedy sampling on
    /// the CPU — argmax plus one log-sum-exp over the raw logits in Float32,
    /// no materialized softmax array and no MLTensor dispatch (~70–100 µs of
    /// per-token overhead). Fallback retries (temperature > 0) keep the
    /// MLTensor top-k path untouched. Exact-argmax and log-prob-tolerance
    /// gates live in GreedySamplerEquivalenceTests.
    private func sampleGreedyOnCPU(logits: MLMultiArray) -> (token: Int, logprob: Float) {
        let count = logits.count
        var floats = [Float](repeating: 0, count: count)
        logits.withUnsafeBytes { rawBuffer in
            let halfBuffer = rawBuffer.bindMemory(to: UInt16.self)
            var sourceBuffer = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: halfBuffer.baseAddress),
                height: 1, width: vImagePixelCount(count), rowBytes: count * 2
            )
            floats.withUnsafeMutableBufferPointer { destination in
                var destinationBuffer = vImage_Buffer(
                    data: destination.baseAddress, height: 1,
                    width: vImagePixelCount(count), rowBytes: count * 4
                )
                vImageConvert_Planar16FtoPlanarF(&sourceBuffer, &destinationBuffer, 0)
            }
        }

        var maxValue: Float = 0
        var maxIndex: vDSP_Length = 0
        vDSP_maxvi(floats, 1, &maxValue, &maxIndex, vDSP_Length(count))

        // logprob = x[argmax] - logsumexp(x), computed max-shifted:
        // logsumexp(x) = max + log(Σ exp(x - max)), so logprob = -log(Σ …).
        var sumOfExponentials: Float = 0
        if maxValue.isFinite {
            var negativeMax = -maxValue
            vDSP_vsadd(floats, 1, &negativeMax, &floats, 1, vDSP_Length(count))
            var elementCount = Int32(count)
            vvexpf(&floats, floats, &elementCount)
            vDSP_sve(floats, 1, &sumOfExponentials, vDSP_Length(count))
            return (token: Int(maxIndex), logprob: -log(sumOfExponentials))
        } else {
            // Degenerate tensors can't occur from real decode filters; match
            // the MLTensor path's observed outputs exactly (pinned by the
            // equivalence suite): ±inf at the max → -inf logprob. NaN inputs
            // are outside the equivalence contract (see the suite).
            return (token: Int(maxIndex), logprob: maxValue.isNaN ? .nan : -.infinity)
        }
    }

    #if canImport(CoreML.MLState)
    @available(macOS 15, iOS 18, watchOS 11, visionOS 2, *)
    private func sampleWithMLTensor(logits: MLMultiArray) async -> (token: Int, logprob: Float) {
        // Use MLTensor operations if available for sampling
        // Reference: https://github.com/huggingface/swift-transformers/blob/preview/Sources/Generation/Decoders.swift
        var logitsTensor = MLTensor(MLShapedArray<FloatType>(logits)).cast(to: Float.self)
        var nextTokenTensor: MLTensor
        var nextLogprobTensor: MLTensor

        if temperature != 0.0 {
            // Scale logits by temperature if > 0
            logitsTensor = logitsTensor / temperature
        }

        // Always softmax once
        let softmaxScores = logitsTensor.softmax(alongAxis: -1)

        if temperature != 0.0 {
            // top-k multinomial sampling
            let (topKProbs, topKIndices) = softmaxScores.topK(decodingOptions.topK)

            let rnd = topKProbs.sum() * nextRandom(in: 0..<1)
            var accumTopKProbs = topKProbs.cumulativeSum(alongAxis: -1)
            accumTopKProbs += (accumTopKProbs .< rnd) * 100.0
            let topKIndex = accumTopKProbs.argsort()[..., 0]

            nextTokenTensor = topKIndices.gathering(
                atIndices: topKIndex,
                alongAxis: topKIndices.rank - 1
            )
            nextLogprobTensor = topKProbs.gathering(
                atIndices: topKIndex,
                alongAxis: topKIndices.rank - 1
            ).log()
        } else {
            nextTokenTensor = logitsTensor.argmax(alongAxis: -1)
            nextLogprobTensor = softmaxScores.gathering(atIndices: nextTokenTensor, alongAxis: -1).log()
        }

        return (
            token: await nextTokenTensor.toIntArray()[0],
            logprob: await nextLogprobTensor.toFloatArray()[0]
        )
    }
    #endif

    private func sampleWithBNNS(logits: MLMultiArray) -> (token: Int, logprob: Float) {
        // TODO: BNNS operations here are deprecated, replace with vDSP or MLX
        var softmaxOutput: BNNSNDArrayDescriptor?
        var argmaxOutput: BNNSNDArrayDescriptor?
        var softmaxInput: BNNSNDArrayDescriptor?
        var softmaxInputNeedsDeallocate = false

        var nextToken: Int?

        do {
            let logitsRawPointer = UnsafeMutableRawBufferPointer(
                start: logits.dataPointer,
                count: logits.count * MemoryLayout<FloatType>.stride
            )

            let logitsDescriptor = BNNSNDArrayDescriptor(
                data: logitsRawPointer,
                scalarType: FloatType.self,
                shape: .vector(logits.count, stride: 1)
            )!

            softmaxInput = logitsDescriptor

            // Scale logits by temperature if > 0
            if temperature != 0.0 {
                let scaledLogits = BNNSNDArrayDescriptor.allocateUninitialized(
                    scalarType: FloatType.self,
                    shape: .vector(logits.count, stride: 1)
                )

                try! BNNS.applyActivation(
                    activation: BNNS.ActivationFunction.linear(alpha: Float(1 / temperature)),
                    input: logitsDescriptor,
                    output: scaledLogits,
                    batchSize: 1
                )

                softmaxInput = scaledLogits
                softmaxInputNeedsDeallocate = true
            }

            // Always softmax once
            softmaxOutput = BNNSNDArrayDescriptor.allocateUninitialized(
                scalarType: Float.self,
                shape: .vector(logits.count, stride: 1)
            )

            try BNNS.applyActivation(
                activation: BNNS.ActivationFunction.softmax,
                input: softmaxInput!,
                output: softmaxOutput!,
                batchSize: 1
            )

            if temperature != 0.0 {
                // top-k multinomial sampling
                let k = decodingOptions.topK
                let bestValues = BNNSNDArrayDescriptor.allocateUninitialized(
                    scalarType: Float.self,
                    shape: .vector(k, stride: 1)
                )
                let bestIndices = BNNSNDArrayDescriptor.allocateUninitialized(
                    scalarType: Int32.self,
                    shape: .vector(k, stride: 1)
                )

                try! BNNS.applyTopK(
                    k: k,
                    input: softmaxOutput!,
                    bestValues: bestValues,
                    bestIndices: bestIndices,
                    axis: 0,
                    batchSize: 1
                )

                let bestValuesResult = bestValues.makeArray(of: Float.self)!
                let bestIndicesResult = bestIndices.makeArray(of: Int32.self)!

                bestValues.deallocate()
                bestIndices.deallocate()

                // multinomial sample from top-k
                let sumOfbestIndicesResult = bestValuesResult.reduce(0, +)
                let rnd = nextRandom(in: 0..<sumOfbestIndicesResult)
                var accumulator = Float(0.0)
                var chosenIndex = 0
                for i in 0..<bestValuesResult.count {
                    accumulator += bestValuesResult[i]
                    if rnd < accumulator {
                        chosenIndex = i
                        break
                    }
                }

                nextToken = Int(bestIndicesResult[chosenIndex])
            } else {
                argmaxOutput = BNNSNDArrayDescriptor.allocateUninitialized(
                    scalarType: Float.self,
                    shape: .vector(1, stride: 1)
                )

                try! BNNS.applyReduction(
                    BNNS.ReductionFunction.argMax,
                    input: logitsDescriptor,
                    output: argmaxOutput!,
                    weights: nil
                )

                let argmaxResult = argmaxOutput!.makeArray(of: Float.self)!

                nextToken = Int(argmaxResult[0])
            }
        } catch {
            Logging.error("Sampling error: \(error)")
        }

        // Log of softmax probability of chosen token
        let softmaxResult = softmaxOutput!.makeArray(of: Float.self)!
        let nextLogprob = log(Float(softmaxResult[nextToken!]))
        // Deallocations
        softmaxOutput?.deallocate()
        argmaxOutput?.deallocate()
        if softmaxInputNeedsDeallocate {
            softmaxInput?.deallocate()
        }

        return (token: nextToken!, logprob: nextLogprob)
    }

    public func update(tokens: [Int], logits: MLMultiArray, logProbs: [Float]) async -> SamplingResult {
        var nextTokens = tokens
        var nextLogprobs = logProbs
        var completed = false

        var result: (token: Int, logprob: Float)
        if temperature == 0.0 {
            result = sampleGreedyOnCPU(logits: logits)
        } else {
            #if canImport(CoreML.MLState)
            if #available(macOS 15.0, iOS 18.0, watchOS 11.0, visionOS 2.0, *) {
                result = await sampleWithMLTensor(logits: logits)
            } else {
                result = sampleWithBNNS(logits: logits)
            }
            #else
            result = sampleWithBNNS(logits: logits)
            #endif
        }

        nextTokens = tokens + [result.token]
        nextLogprobs = logProbs + [result.logprob]
        completed = result.token == eotToken

        return SamplingResult(
            tokens: nextTokens,
            logProbs: nextLogprobs,
            completed: completed
        )
    }

    public func finalize(tokens: [Int], logProbs: [Float]) -> SamplingResult {
        var finalTokens = tokens
        var finalLogProbs = logProbs
        if tokens.last != eotToken {
            finalTokens.append(eotToken)
            finalLogProbs.append(0)
        }

        return SamplingResult(tokens: finalTokens, logProbs: finalLogProbs, completed: true)
    }
}

open class BeamSearchTokenSampler: TokenSampling {
    public var beamSize: Int
    public var eotToken: Int
    public var patience: Float
    var maxCandidates: Int
    var finishedSequences: [Float]

    public init(
        beamSize: Int,
        eotToken: Int,
        patience: Float = 1
    ) {
        self.beamSize = beamSize
        self.eotToken = eotToken
        self.patience = patience
        self.maxCandidates = Int(Float(beamSize) * patience)
        self.finishedSequences = []
        if self.maxCandidates <= 0 {
            self.maxCandidates = 1
            fatalError("Invalid beam size \(beamSize) or patience \(patience)")
        }
    }

    public func reset() {
        finishedSequences = []
    }

    public func update(tokens: [Int], logits: MLMultiArray, logProbs: [Float]) async -> SamplingResult {
        // TODO: Implement
        fatalError("Not implemented: \(#function)")
    }

    public func finalize(tokens: [Int], logProbs: [Float]) -> SamplingResult {
        // TODO: Implement
        fatalError("Not implemented: \(#function)")
    }
}
