import CoreML
import Foundation
import Testing
@preconcurrency import WhisperKit

/// C1/D1 harness (whisper-perf): gates the production KV scatter
/// (serial typed 16-bit loop since D1) bit-identically against the upstream
/// concurrentPerform reference on real Tiny cache shapes. Correctness always
/// runs; the timing pass is opt-in via OPENCAST_KV_MICROBENCH=1 so routine
/// test runs stay fast.
@Suite("KV scatter microbenchmark", .serialized)
struct KVScatterMicrobenchmarkTests {
    private static let embedDim = 1536
    private static let maxSequenceLength = 448

    private func makeTensor(shape: [Int], fill: (Int) -> Float16) throws -> MLMultiArray {
        let tensor = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .float16)
        tensor.withUnsafeMutableBytes { pointer, _ in
            let buffer = pointer.bindMemory(to: Float16.self)
            for index in 0..<buffer.count {
                buffer[index] = fill(index)
            }
        }
        return tensor
    }

    private func tensorData(_ tensor: MLMultiArray) -> Data {
        tensor.withUnsafeBytes { Data($0) }
    }

    private func makeCache() throws -> MLMultiArray {
        try makeTensor(shape: [1, Self.embedDim, 1, Self.maxSequenceLength]) { _ in 0 }
    }

    private func makeSlice(width: Int, seed: Float16) throws -> MLMultiArray {
        try makeTensor(shape: [1, Self.embedDim, 1, width]) { index in
            seed + Float16(index % 251) / 251
        }
    }

    /// Upstream WhisperKit scatter (concurrentPerform + per-element memcpy),
    /// preserved as the bit-identity reference for the production swap.
    private func upstreamConcurrentUpdate(
        keyTensor: MLMultiArray,
        keySlice: MLMultiArray,
        valueTensor: MLMultiArray,
        valueSlice: MLMultiArray,
        insertAtIndex index: Int
    ) {
        let tensorShape = keyTensor.shape.map { $0.intValue }
        let sliceShape = keySlice.shape.map { $0.intValue }
        let sliceStrides = keySlice.strides.map { $0.intValue }
        let bytesPerSample = MemoryLayout<Float16>.size

        keyTensor.withUnsafeMutableBytes { keyTensorPointer, keyTargetStrides in
            keySlice.withUnsafeBytes { keySlicePointer in
                valueTensor.withUnsafeMutableBytes { valueTensorPointer, valueTargetStrides in
                    valueSlice.withUnsafeBytes { valueSlicePointer in
                        guard
                            let keyDestBaseAddress = keyTensorPointer.baseAddress,
                            let keySrcBaseAddress = keySlicePointer.baseAddress,
                            let valDestBaseAddress = valueTensorPointer.baseAddress,
                            let valSrcBaseAddress = valueSlicePointer.baseAddress
                        else { return }
                        nonisolated(unsafe) let keyDestBase = keyDestBaseAddress
                        nonisolated(unsafe) let keySrcBase = keySrcBaseAddress
                        nonisolated(unsafe) let valDestBase = valDestBaseAddress
                        nonisolated(unsafe) let valSrcBase = valSrcBaseAddress
                        DispatchQueue.concurrentPerform(iterations: tensorShape[1]) { j in
                            for k in 0..<sliceShape[3] {
                                let keyDestIndex = j * keyTargetStrides[1] + (index + k) * keyTargetStrides[3]
                                let keyDest = keyDestBase + keyDestIndex * bytesPerSample

                                let keySliceIndex = j * sliceStrides[1] + k * sliceStrides[3]
                                let keySrc = keySrcBase + keySliceIndex * bytesPerSample
                                memcpy(keyDest, keySrc, bytesPerSample)

                                let valDestIndex = j * valueTargetStrides[1] + (index + k) * valueTargetStrides[3]
                                let valDest = valDestBase + valDestIndex * bytesPerSample

                                let valSliceIndex = j * sliceStrides[1] + k * sliceStrides[3]
                                let valSrc = valSrcBase + valSliceIndex * bytesPerSample
                                memcpy(valDest, valSrc, bytesPerSample)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Same math as upstream updateKVCache, without DispatchQueue dispatch.
    private func serialMemcpyUpdate(
        keyTensor: MLMultiArray,
        keySlice: MLMultiArray,
        valueTensor: MLMultiArray,
        valueSlice: MLMultiArray,
        insertAtIndex index: Int
    ) {
        let embedCount = keyTensor.shape[1].intValue
        let sliceWidth = keySlice.shape[3].intValue
        let sliceStrides = keySlice.strides.map { $0.intValue }
        let bytesPerSample = MemoryLayout<Float16>.size

        keyTensor.withUnsafeMutableBytes { keyDestPointer, keyStrides in
            keySlice.withUnsafeBytes { keySrcPointer in
                valueTensor.withUnsafeMutableBytes { valDestPointer, valStrides in
                    valueSlice.withUnsafeBytes { valSrcPointer in
                        guard let keyDestBase = keyDestPointer.baseAddress,
                              let keySrcBase = keySrcPointer.baseAddress,
                              let valDestBase = valDestPointer.baseAddress,
                              let valSrcBase = valSrcPointer.baseAddress
                        else { return }
                        for j in 0..<embedCount {
                            for k in 0..<sliceWidth {
                                memcpy(
                                    keyDestBase + (j * keyStrides[1] + (index + k) * keyStrides[3]) * bytesPerSample,
                                    keySrcBase + (j * sliceStrides[1] + k * sliceStrides[3]) * bytesPerSample,
                                    bytesPerSample
                                )
                                memcpy(
                                    valDestBase + (j * valStrides[1] + (index + k) * valStrides[3]) * bytesPerSample,
                                    valSrcBase + (j * sliceStrides[1] + k * sliceStrides[3]) * bytesPerSample,
                                    bytesPerSample
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("Production scatter is bit-identical to the upstream concurrent scatter")
    func productionMatchesUpstreamReference() async throws {
        // Insert width 1 at first/middle/last valid index, and width 3 (prefill)
        // at the start, mirroring prefill + decode-loop shapes.
        let cases: [(width: Int, indexes: [Int])] = [
            (1, [0, Self.maxSequenceLength / 2, Self.maxSequenceLength - 1]),
            (3, [0, 200, Self.maxSequenceLength - 3]),
        ]

        for testCase in cases {
            for insertIndex in testCase.indexes {
                let keySlice = try makeSlice(width: testCase.width, seed: 0.25)
                let valueSlice = try makeSlice(width: testCase.width, seed: 0.5)

                let upstreamKey = try makeCache()
                let upstreamValue = try makeCache()
                upstreamConcurrentUpdate(
                    keyTensor: upstreamKey, keySlice: keySlice,
                    valueTensor: upstreamValue, valueSlice: valueSlice,
                    insertAtIndex: insertIndex
                )

                let memcpyKey = try makeCache()
                let memcpyValue = try makeCache()
                serialMemcpyUpdate(
                    keyTensor: memcpyKey, keySlice: keySlice,
                    valueTensor: memcpyValue, valueSlice: valueSlice,
                    insertAtIndex: insertIndex
                )

                let productionKey = try makeCache()
                let productionValue = try makeCache()
                TextDecoder.updateKVCache(
                    keyTensor: productionKey, keySlice: keySlice,
                    valueTensor: productionValue, valueSlice: valueSlice,
                    insertAtIndex: insertIndex
                )

                #expect(tensorData(memcpyKey) == tensorData(upstreamKey), "memcpy key width=\(testCase.width) index=\(insertIndex)")
                #expect(tensorData(memcpyValue) == tensorData(upstreamValue), "memcpy value width=\(testCase.width) index=\(insertIndex)")
                #expect(tensorData(productionKey) == tensorData(upstreamKey), "production key width=\(testCase.width) index=\(insertIndex)")
                #expect(tensorData(productionValue) == tensorData(upstreamValue), "production value width=\(testCase.width) index=\(insertIndex)")
            }
        }
    }

    @Test("Production scatter round-trips a simulated fallback reset")
    func productionMatchesUpstreamThroughFallbackReset() async throws {
        // A fallback retry re-prefills at index 0 and re-decodes over a cache
        // that already holds a partial window. Replay that sequence through
        // both implementations and require bit-identical caches at the end.
        let sequence: [(width: Int, index: Int)] = [
            (3, 0), (1, 3), (1, 4), (1, 5), // first attempt
            (3, 0), (1, 3), (1, 4), // fallback: re-prefill over stale entries
        ]

        let upstreamKey = try makeCache()
        let upstreamValue = try makeCache()
        let productionKey = try makeCache()
        let productionValue = try makeCache()

        for (step, insert) in sequence.enumerated() {
            let keySlice = try makeSlice(width: insert.width, seed: Float16(0.1) + Float16(step) / 16)
            let valueSlice = try makeSlice(width: insert.width, seed: Float16(0.6) + Float16(step) / 16)
            upstreamConcurrentUpdate(
                keyTensor: upstreamKey, keySlice: keySlice,
                valueTensor: upstreamValue, valueSlice: valueSlice,
                insertAtIndex: insert.index
            )
            TextDecoder.updateKVCache(
                keyTensor: productionKey, keySlice: keySlice,
                valueTensor: productionValue, valueSlice: valueSlice,
                insertAtIndex: insert.index
            )
        }

        #expect(tensorData(productionKey) == tensorData(upstreamKey))
        #expect(tensorData(productionValue) == tensorData(upstreamValue))
    }

    @Test("Timing pass")
    func timingPass() async throws {
        guard ProcessInfo.processInfo.environment["OPENCAST_KV_MICROBENCH"] == "1" else {
            return
        }

        let keySlice = try makeSlice(width: 1, seed: 0.25)
        let valueSlice = try makeSlice(width: 1, seed: 0.5)
        let prefillKeySlice = try makeSlice(width: 3, seed: 0.25)
        let prefillValueSlice = try makeSlice(width: 3, seed: 0.5)
        let keyTensor = try makeCache()
        let valueTensor = try makeCache()

        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
            return user + system
        }

        func bench(
            _ name: String,
            rounds: Int = 5,
            _ update: (MLMultiArray, MLMultiArray, MLMultiArray, MLMultiArray, Int) -> Void
        ) {
            let decodeIndexes = Array(3..<Self.maxSequenceLength)
            // Warmup round.
            update(keyTensor, prefillKeySlice, valueTensor, prefillValueSlice, 0)
            for index in decodeIndexes {
                update(keyTensor, keySlice, valueTensor, valueSlice, index)
            }

            var totalUpdates = 0
            let clock = ContinuousClock()
            let cpuStart = cpuSeconds()
            let start = clock.now
            for _ in 0..<rounds {
                update(keyTensor, prefillKeySlice, valueTensor, prefillValueSlice, 0)
                totalUpdates += 1
                for index in decodeIndexes {
                    update(keyTensor, keySlice, valueTensor, valueSlice, index)
                    totalUpdates += 1
                }
            }
            let wall = start.duration(to: clock.now)
            let cpu = cpuSeconds() - cpuStart
            let wallSeconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
            let nsPerUpdate = wallSeconds * 1e9 / Double(totalUpdates)
            print("KV_MICROBENCH variant=\(name) updates=\(totalUpdates) wall_s=\(String(format: "%.6f", wallSeconds)) cpu_s=\(String(format: "%.6f", cpu)) ns_per_update=\(String(format: "%.0f", nsPerUpdate))")
        }

        bench("upstreamConcurrent") { kt, ks, vt, vs, index in
            upstreamConcurrentUpdate(keyTensor: kt, keySlice: ks, valueTensor: vt, valueSlice: vs, insertAtIndex: index)
        }
        bench("serialMemcpy") { kt, ks, vt, vs, index in
            serialMemcpyUpdate(keyTensor: kt, keySlice: ks, valueTensor: vt, valueSlice: vs, insertAtIndex: index)
        }
        bench("productionSerialTyped") { kt, ks, vt, vs, index in
            TextDecoder.updateKVCache(keyTensor: kt, keySlice: ks, valueTensor: vt, valueSlice: vs, insertAtIndex: index)
        }
        // Repeat in reverse order so ordering/thermal effects show up as disagreement.
        bench("productionSerialTyped#2") { kt, ks, vt, vs, index in
            TextDecoder.updateKVCache(keyTensor: kt, keySlice: ks, valueTensor: vt, valueSlice: vs, insertAtIndex: index)
        }
        bench("serialMemcpy#2") { kt, ks, vt, vs, index in
            serialMemcpyUpdate(keyTensor: kt, keySlice: ks, valueTensor: vt, valueSlice: vs, insertAtIndex: index)
        }
        bench("upstreamConcurrent#2") { kt, ks, vt, vs, index in
            upstreamConcurrentUpdate(keyTensor: kt, keySlice: ks, valueTensor: vt, valueSlice: vs, insertAtIndex: index)
        }
    }
}
