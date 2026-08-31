import CoreML
import Foundation
import Testing
@testable import OpenCastTranscription
@preconcurrency import WhisperKit

/// Measure-only probe: decoder-only specialization
/// hint matrix — default vs .fastPrediction vs .fastPrediction + infrequent
/// reshapes. Reports load time (per fresh MLModel.load in this process),
/// warm per-token latency over production decode shapes (width-3 prefill +
/// width-1 loop), peak footprint delta, and Core ML cache growth.
/// Production adoption remains a separate decision.
///
/// OPENCAST_SPECIALIZATION_PROBE=1 enables it. Cache-cold "first ever" load
/// numbers require wiping the e5rt bundle cache between runs, which this
/// probe does not do — run variants in separate processes and compare cache
/// dir growth instead.
@Suite("Specialization hints probe", .serialized)
struct SpecializationHintsProbeTests {
    private func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    private func cacheBytes() -> Int64 {
        // e5rt specialization bundle cache in the user cache dir.
        var bytes: Int64 = 0
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        for name in ["com.apple.e5rt.e5bundlecache", "com.apple.CoreML"] {
            guard let dir = base?.appending(path: name),
                  let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in enumerator {
                bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return bytes
    }

    @Test("Decoder specialization matrix", .timeLimit(.minutes(15)))
    func decoderSpecializationMatrix() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENCAST_SPECIALIZATION_PROBE"] == "1" else { return }
        let variantFilter = environment["OPENCAST_SPECIALIZATION_VARIANT"]

        let location = try DownloadedWhisperModelLocator(model: .tinyEnglish).modelLocation()
        let decoderURL = location.modelFolder.appending(path: "TextDecoder.mlmodelc")

        let embedDim = 1536, maxSeq = 448, encoderDim = 384, encoderSeq = 1500
        func provider(width: Int) throws -> MLDictionaryFeatureProvider {
            let inputIds = try MLMultiArray(shape: [NSNumber(value: width)], dataType: .int32, initialValue: Int32(0))
            let inputs: [String: MLMultiArray] = try [
                "input_ids": inputIds,
                "cache_length": MLMultiArray(shape: [1], dataType: .int32, initialValue: Int32(3)),
                "key_cache": MLMultiArray(shape: [1, NSNumber(value: embedDim), 1, NSNumber(value: maxSeq)], dataType: .float16, initialValue: 0),
                "value_cache": MLMultiArray(shape: [1, NSNumber(value: embedDim), 1, NSNumber(value: maxSeq)], dataType: .float16, initialValue: 0),
                "kv_cache_update_mask": MLMultiArray(shape: [1, NSNumber(value: maxSeq)], dataType: .int32, initialValue: Int32(0)),
                "encoder_output_embeds": MLMultiArray(shape: [1, NSNumber(value: encoderDim), 1, NSNumber(value: encoderSeq)], dataType: .float16, initialValue: 0),
                "decoder_key_padding_mask": MLMultiArray(shape: [1, NSNumber(value: maxSeq)], dataType: .float16, initialValue: 0),
            ]
            return try MLDictionaryFeatureProvider(dictionary: inputs.mapValues(MLFeatureValue.init(multiArray:)))
        }

        let variants: [(label: String, configure: (MLModelConfiguration) -> Void)] = [
            ("default", { _ in }),
            ("fastPrediction", { configuration in
                var hints = MLOptimizationHints()
                hints.specializationStrategy = .fastPrediction
                configuration.optimizationHints = hints
            }),
            ("fastPrediction+infrequentReshape", { configuration in
                var hints = MLOptimizationHints()
                hints.specializationStrategy = .fastPrediction
                hints.reshapeFrequency = .infrequent
                configuration.optimizationHints = hints
            }),
        ]

        let clock = ContinuousClock()
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }

        for variant in variants where variantFilter == nil || variant.label == variantFilter {
            let cacheBefore = cacheBytes()
            let footprintBefore = footprint()

            // Load twice: the first is this process's uncached-or-warm load,
            // the second measures the per-load floor with a hot cache.
            var loadSeconds: [Double] = []
            var model: MLModel?
            for _ in 0..<2 {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .cpuAndNeuralEngine
                variant.configure(configuration)
                let start = clock.now
                model = try await MLModel.load(contentsOf: decoderURL, configuration: configuration)
                loadSeconds.append(seconds(start.duration(to: clock.now)))
            }
            guard let model else { continue }

            // Warm per-token latency. input_ids is fixed shape (1) — the
            // decoder never reshapes, so reshapeFrequency has no shape
            // variance to help with; measured anyway for the record.
            let decode = try provider(width: 1)
            for _ in 0..<10 { _ = try await model.prediction(from: decode, options: MLPredictionOptions()) }

            var decodeDuration = Duration.zero
            let windows = 4, decodesPerWindow = 60
            for _ in 0..<windows {
                let start = clock.now
                for _ in 0..<decodesPerWindow {
                    _ = try await model.prediction(from: decode, options: MLPredictionOptions())
                }
                decodeDuration += start.duration(to: clock.now)
            }
            let prefillDuration = Duration.zero

            let footprintAfter = footprint()
            let cacheAfter = cacheBytes()
            print("E3_PROBE variant=\(variant.label) load1_s=\(String(format: "%.3f", loadSeconds[0])) load2_s=\(String(format: "%.3f", loadSeconds[1])) warmDecode_ms=\(String(format: "%.2f", seconds(decodeDuration) * 1000 / Double(windows * decodesPerWindow))) prefill_ms=\(String(format: "%.2f", seconds(prefillDuration) * 1000 / Double(windows))) footprintDelta_mb=\(String(format: "%.0f", Double(footprintAfter - footprintBefore) / 1e6)) cacheDelta_mb=\(String(format: "%.1f", Double(cacheAfter - cacheBefore) / 1e6))")
        }
    }
}
