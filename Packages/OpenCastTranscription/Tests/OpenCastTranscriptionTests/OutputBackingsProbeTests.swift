import CoreML
import Foundation
import Testing
@testable import OpenCastTranscription
@preconcurrency import WhisperKit

/// D4 probe (whisper-perf pass 2, measure-first): does Core ML honor
/// caller-owned `MLPredictionOptions.outputBackings` for the Tiny decoder's
/// ML Program, and do allocations actually fall? Hard stop if not honored —
/// that answers the open question either way; no production change happens
/// from this test.
///
/// OPENCAST_OUTPUT_BACKINGS_PROBE=1 enables it (needs the local Tiny model).
@Suite("Output backings probe", .serialized)
struct OutputBackingsProbeTests {
    private func pageAlignedArray(shape: [NSNumber], dataType: MLMultiArrayDataType) throws -> MLMultiArray {
        let elementCount = shape.reduce(1) { $0 * $1.intValue }
        let bytesPerElement = dataType == .float16 ? 2 : 4
        let byteCount = max(elementCount * bytesPerElement, 16)
        var pointer: UnsafeMutableRawPointer?
        guard posix_memalign(&pointer, Int(getpagesize()), byteCount) == 0, let pointer else {
            throw WhisperError.transcriptionFailed("posix_memalign failed")
        }
        memset(pointer, 0, byteCount)
        return try MLMultiArray(
            dataPointer: pointer,
            shape: shape,
            dataType: dataType,
            strides: contiguousStrides(for: shape),
            deallocator: { free($0) }
        )
    }

    private func contiguousStrides(for shape: [NSNumber]) -> [NSNumber] {
        var strides = [Int](repeating: 1, count: shape.count)
        for index in stride(from: shape.count - 2, through: 0, by: -1) {
            strides[index] = strides[index + 1] * shape[index + 1].intValue
        }
        return strides.map(NSNumber.init(value:))
    }

    private func mallocStats() -> (blocks: Int, bytes: Int) {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return (Int(stats.blocks_in_use), Int(stats.size_in_use))
    }

    @Test(
        "Decoder outputBackings identity and allocation probe",
        .timeLimit(.minutes(10)),
        .enabled(if: ProcessInfo.processInfo.environment["OPENCAST_OUTPUT_BACKINGS_PROBE"] == "1")
    )
    func decoderOutputBackingsProbe() async throws {

        let location = try DownloadedWhisperModelLocator(model: .tinyEnglish).modelLocation()
        let decoderURL = location.modelFolder.appending(path: "TextDecoder.mlmodelc")

        for computeUnits: MLComputeUnits in [.cpuAndNeuralEngine, .cpuOnly] {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            let model = try await MLModel.load(contentsOf: decoderURL, configuration: configuration)
            let unitsLabel = computeUnits == .cpuOnly ? "cpuOnly" : "cpuAndNeuralEngine"

            // Build production-shaped inputs (decode step, width 1).
            let embedDim = 1536, maxSeq = 448, encoderDim = 384, encoderSeq = 1500
            let inputs: [String: MLMultiArray] = try [
                "input_ids": MLMultiArray(shape: [1], dataType: .int32, initialValue: Int32(0)),
                "cache_length": MLMultiArray(shape: [1], dataType: .int32, initialValue: Int32(3)),
                "key_cache": MLMultiArray(shape: [1, NSNumber(value: embedDim), 1, NSNumber(value: maxSeq)], dataType: .float16, initialValue: 0),
                "value_cache": MLMultiArray(shape: [1, NSNumber(value: embedDim), 1, NSNumber(value: maxSeq)], dataType: .float16, initialValue: 0),
                "kv_cache_update_mask": MLMultiArray(shape: [1, NSNumber(value: maxSeq)], dataType: .int32, initialValue: Int32(0)),
                "encoder_output_embeds": MLMultiArray(shape: [1, NSNumber(value: encoderDim), 1, NSNumber(value: encoderSeq)], dataType: .float16, initialValue: 0),
                "decoder_key_padding_mask": MLMultiArray(shape: [1, NSNumber(value: maxSeq)], dataType: .float16, initialValue: 0),
            ]
            let provider = try MLDictionaryFeatureProvider(dictionary: inputs.mapValues(MLFeatureValue.init(multiArray:)))

            // Discover output names/shapes from a plain prediction.
            let plain = try await model.prediction(from: provider, options: MLPredictionOptions())
            var outputShapes: [String: [NSNumber]] = [:]
            for name in plain.featureNames {
                if let array = plain.featureValue(for: name)?.multiArrayValue {
                    outputShapes[name] = array.shape
                }
            }
            print("D4_PROBE units=\(unitsLabel) outputs=\(outputShapes.map { "\($0.key)\($0.value)" }.sorted().joined(separator: " "))")

            // Page-aligned backings, one options object reused per "window".
            var backings: [String: MLMultiArray] = [:]
            for (name, shape) in outputShapes {
                backings[name] = try pageAlignedArray(shape: shape, dataType: .float16)
            }
            let options = MLPredictionOptions()
            options.outputBackings = backings

            let iterations = 60
            var hits = [String: Int]()

            // Warmup + measure loop with backings.
            for _ in 0..<5 { _ = try await model.prediction(from: provider, options: options) }
            let statsBeforeBacked = mallocStats()
            let clock = ContinuousClock()
            let backedStart = clock.now
            for _ in 0..<iterations {
                let out = try await model.prediction(from: provider, options: options)
                for (name, backing) in backings {
                    if let array = out.featureValue(for: name)?.multiArrayValue,
                       array.dataPointer == backing.dataPointer {
                        hits[name, default: 0] += 1
                    }
                }
            }
            let backedDuration = backedStart.duration(to: clock.now)
            let statsAfterBacked = mallocStats()

            // Baseline loop without backings.
            for _ in 0..<5 { _ = try await model.prediction(from: provider, options: MLPredictionOptions()) }
            let statsBeforePlain = mallocStats()
            let plainStart = clock.now
            for _ in 0..<iterations {
                _ = try await model.prediction(from: provider, options: MLPredictionOptions())
            }
            let plainDuration = plainStart.duration(to: clock.now)
            let statsAfterPlain = mallocStats()

            func ms(_ duration: Duration) -> String {
                String(format: "%.2f", (Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 1000 / Double(iterations))
            }
            let hitSummary = outputShapes.keys.sorted().map { "\($0)=\(hits[$0, default: 0])/\(iterations)" }.joined(separator: " ")
            print("D4_PROBE units=\(unitsLabel) identityHits: \(hitSummary)")
            print("D4_PROBE units=\(unitsLabel) perCall_ms backed=\(ms(backedDuration)) plain=\(ms(plainDuration)) mallocDelta backed=\(statsAfterBacked.blocks - statsBeforeBacked.blocks)blk/\(statsAfterBacked.bytes - statsBeforeBacked.bytes)B plain=\(statsAfterPlain.blocks - statsBeforePlain.blocks)blk/\(statsAfterPlain.bytes - statsBeforePlain.bytes)B")
        }
    }
}
