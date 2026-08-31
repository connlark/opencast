@preconcurrency import CoreML
import Foundation

/// Opt-in, measure-only stateful decoder probe:
/// per-forward microbenchmark for Tiny bundle candidates.
///
/// Loads compiled bundles from `Documents/StatefulSpike/*.mlmodelc` in the
/// app container (pushed via devicectl; never part of the app bundle or the
/// model manifest), reports MLComputePlan device placement, and times
/// forwards per schema: decoders (manual-cache or MLState) sweep width-1
/// forwards across cache-fill levels; MelSpectrogram and AudioEncoder
/// bundles time whole forwards. Nothing here touches the product
/// transcription path.
nonisolated enum StatefulSpikeDecoderProbe {
    static let requestArgument = "--opencast-stateful-spike-probe"
    static let requestEnvironmentKey = "OPENCAST_STATEFUL_SPIKE_PROBE"
    static let subdirectoryArgument = "--opencast-stateful-spike-subdir"
    static let subdirectoryEnvironmentKey = "OPENCAST_STATEFUL_SPIKE_SUBDIR"

    private static let kvSequenceLength = 448
    private static let fusedCacheChannels = 1536
    private static let embedDimension = 384
    private static let encoderSequenceLength = 1500
    private static let fillLevels = [0, 31, 63, 95, 127, 159, 191, 223]
    private static let iterationsPerFill = 24
    private static let warmupIterationsPerFill = 4

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(requestArgument)
            || ProcessInfo.processInfo.environment[requestEnvironmentKey] == "1"
    }

    static func run(runLabel: String?, commit: String?) async {
        var report: [String: Any] = [
            "status": "running",
            "probe": "stateful-spike-decoder",
            "runLabel": runLabel ?? "spike",
            "commit": commit ?? "",
            "createdAt": ISO8601DateFormatter().string(from: .now),
            "computeUnits": computeUnitsDescription,
            "fillLevels": fillLevels,
            "iterationsPerFill": iterationsPerFill,
        ]
        var modelReports: [[String: Any]] = []

        let arguments = ProcessInfo.processInfo.arguments
        let subdirectory = arguments.firstIndex(of: subdirectoryArgument)
            .flatMap { index in arguments.indices.contains(index + 1) ? arguments[index + 1] : nil }
            ?? ProcessInfo.processInfo.environment[subdirectoryEnvironmentKey]
            ?? "StatefulSpike"
        report["spikeSubdirectory"] = subdirectory
        let spikeDirectory = URL.documentsDirectory.appending(path: subdirectory, directoryHint: .isDirectory)
        let bundles = ((try? FileManager.default.contentsOfDirectory(at: spikeDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "mlmodelc" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        if bundles.isEmpty {
            report["error"] = "no .mlmodelc bundles under \(spikeDirectory.path)"
        }
        for bundle in bundles {
            modelReports.append(await measure(bundle: bundle))
        }

        report["models"] = modelReports
        report["status"] = "completed"
        report["completedAt"] = ISO8601DateFormatter().string(from: .now)
        write(report, runLabel: runLabel)
    }

    private static var computeUnits: MLComputeUnits {
        switch ProcessInfo.processInfo.environment["OPENCAST_STATEFUL_SPIKE_COMPUTE"] {
        case "cpuOnly": .cpuOnly
        case "all": .all
        default: .cpuAndNeuralEngine
        }
    }

    private static var computeUnitsDescription: String {
        switch computeUnits {
        case .cpuOnly: "cpuOnly"
        case .all: "all"
        case .cpuAndNeuralEngine: "cpuAndNeuralEngine"
        case .cpuAndGPU: "cpuAndGPU"
        @unknown default: "unknown"
        }
    }

    private static func measure(bundle: URL) async -> [String: Any] {
        var entry: [String: Any] = ["name": bundle.deletingPathExtension().lastPathComponent]
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits

        let clock = ContinuousClock()
        let loadStart = clock.now
        let model: MLModel
        do {
            model = try await MLModel.load(contentsOf: bundle, configuration: configuration)
        } catch {
            entry["loadError"] = String(describing: error)
            return entry
        }
        entry["loadSeconds"] = loadStart.duration(to: clock.now).seconds

        entry["computePlan"] = await computePlanSummary(bundle: bundle, configuration: configuration)

        let inputNames = Set(model.modelDescription.inputDescriptionsByName.keys)
        if inputNames.contains("audio") {
            entry["schema"] = "melSpectrogram"
            await measureWholeForwards(model: model, into: &entry, makeProvider: melProvider)
            return entry
        }
        if inputNames.contains("melspectrogram_features"), !inputNames.contains("input_ids") {
            entry["schema"] = "audioEncoder"
            await measureWholeForwards(model: model, into: &entry, makeProvider: encoderProvider)
            return entry
        }

        let isStateful = !model.modelDescription.stateDescriptionsByName.isEmpty
        entry["schema"] = isStateful ? "stateful" : "manualCache"

        do {
            let inputs = try SpikeDecoderInputs()
            var fillMedians: [String: Double] = [:]
            var allSamples: [Double] = []
            for fill in fillLevels {
                let state = isStateful ? model.makeState() : nil
                var samples: [Double] = []
                for iteration in 0..<iterationsPerFill {
                    let provider = try inputs.provider(fill: fill, includeCaches: !isStateful)
                    let start = clock.now
                    if let state {
                        _ = try await model.prediction(from: provider, using: state)
                    } else {
                        _ = try await model.prediction(from: provider)
                    }
                    let elapsed = start.duration(to: clock.now).seconds
                    if iteration >= warmupIterationsPerFill {
                        samples.append(elapsed)
                    }
                }
                samples.sort()
                let median = samples[samples.count / 2]
                fillMedians["fill\(fill)"] = median * 1000
                allSamples.append(contentsOf: samples)
            }
            allSamples.sort()
            entry["medianForwardMsByFill"] = fillMedians
            entry["overallMedianForwardMs"] = allSamples[allSamples.count / 2] * 1000
        } catch {
            entry["predictionError"] = String(describing: error)
        }
        return entry
    }

    private static func measureWholeForwards(
        model: MLModel,
        into entry: inout [String: Any],
        makeProvider: () throws -> MLFeatureProvider
    ) async {
        let clock = ContinuousClock()
        do {
            var samples: [Double] = []
            for iteration in 0..<iterationsPerFill {
                let provider = try makeProvider()
                let start = clock.now
                _ = try await model.prediction(from: provider)
                let elapsed = start.duration(to: clock.now).seconds
                if iteration >= warmupIterationsPerFill {
                    samples.append(elapsed)
                }
            }
            samples.sort()
            entry["overallMedianForwardMs"] = samples[samples.count / 2] * 1000
            entry["minForwardMs"] = samples.first.map { $0 * 1000 }
            entry["maxForwardMs"] = samples.last.map { $0 * 1000 }
        } catch {
            entry["predictionError"] = String(describing: error)
        }
    }

    private static func melProvider() throws -> MLFeatureProvider {
        let audio = try MLMultiArray(shape: [480_000], dataType: .float16)
        let pointer = audio.dataPointer.assumingMemoryBound(to: UInt16.self)
        for index in 0..<audio.count {
            pointer[index] = Float16(sinf(Float(index) * 0.00113) * 0.2).bitPattern
        }
        return try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: audio)])
    }

    private static func encoderProvider() throws -> MLFeatureProvider {
        let mel = try MLMultiArray(shape: [1, 80, 1, 3000], dataType: .float16)
        let pointer = mel.dataPointer.assumingMemoryBound(to: UInt16.self)
        for index in 0..<mel.count {
            pointer[index] = Float16(sinf(Float(index) * 0.0137) * 0.4).bitPattern
        }
        return try MLDictionaryFeatureProvider(
            dictionary: ["melspectrogram_features": MLFeatureValue(multiArray: mel)]
        )
    }

    /// Per-op preferred-device counts — the direct answer to "did the ANE
    /// accept this graph" that host E5RT refused to give for the stateful
    /// variants.
    private static func computePlanSummary(bundle: URL, configuration: MLModelConfiguration) async -> [String: Any] {
        do {
            let plan = try await MLComputePlan.load(contentsOf: bundle, configuration: configuration)
            guard case .program(let program) = plan.modelStructure,
                  let mainFunction = program.functions["main"] else {
                return ["error": "unexpected model structure"]
            }
            var counts: [String: Int] = [:]
            for operation in mainFunction.block.operations {
                guard let usage = plan.deviceUsage(for: operation) else {
                    continue
                }
                let kind = deviceDescription(usage.preferred)
                counts[kind, default: 0] += 1
            }
            return ["preferredDeviceOpCounts": counts]
        } catch {
            return ["error": String(describing: error)]
        }
    }

    private static func deviceDescription(_ device: MLComputeDevice) -> String {
        switch device {
        case .cpu: "cpu"
        case .gpu: "gpu"
        case .neuralEngine: "neuralEngine"
        @unknown default: "unknown"
        }
    }

    private static func write(_ report: [String: Any], runLabel: String?) {
        let directory = URL.applicationSupportDirectory
            .appending(path: "OpenCastTranscriptionBenchmark", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let stem = (runLabel ?? "spike").replacingOccurrences(of: " ", with: "-")
        let url = directory.appending(path: "benchmark-\(stem)-\(timestamp).json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}

/// Reusable decoder inputs. Cache arrays are allocated once and reused —
/// the timed prediction call includes CoreML's own input transfer, which is
/// exactly the manual-vs-stateful difference under measurement.
private nonisolated final class SpikeDecoderInputs {
    private let keyCache: MLMultiArray
    private let valueCache: MLMultiArray
    private let encoderEmbeds: MLMultiArray

    init() throws {
        keyCache = try MLMultiArray(shape: [1, 1536, 1, 448], dataType: .float16)
        valueCache = try MLMultiArray(shape: [1, 1536, 1, 448], dataType: .float16)
        encoderEmbeds = try MLMultiArray(shape: [1, 384, 1, 1500], dataType: .float16)
        Self.fillDeterministic(keyCache, scale: 0.05)
        Self.fillDeterministic(valueCache, scale: 0.05)
        Self.fillDeterministic(encoderEmbeds, scale: 0.3)
    }

    func provider(fill: Int, includeCaches: Bool) throws -> MLFeatureProvider {
        let inputIDs = try MLMultiArray(shape: [1], dataType: .int32)
        inputIDs[0] = NSNumber(value: 464)
        let cacheLength = try MLMultiArray(shape: [1], dataType: .int32)
        cacheLength[0] = NSNumber(value: Int32(fill))

        let updateMask = try MLMultiArray(shape: [1, 448], dataType: .float16)
        let paddingMask = try MLMultiArray(shape: [1, 448], dataType: .float16)
        let updatePointer = updateMask.dataPointer.assumingMemoryBound(to: UInt16.self)
        let paddingPointer = paddingMask.dataPointer.assumingMemoryBound(to: UInt16.self)
        let zero = Float16(0).bitPattern
        let one = Float16(1).bitPattern
        let masked = Float16(-10000).bitPattern
        for index in 0..<448 {
            updatePointer[index] = index == fill ? one : zero
            paddingPointer[index] = index <= fill ? zero : masked
        }

        var features: [String: MLFeatureValue] = [
            "input_ids": MLFeatureValue(multiArray: inputIDs),
            "cache_length": MLFeatureValue(multiArray: cacheLength),
            "kv_cache_update_mask": MLFeatureValue(multiArray: updateMask),
            "encoder_output_embeds": MLFeatureValue(multiArray: encoderEmbeds),
            "decoder_key_padding_mask": MLFeatureValue(multiArray: paddingMask),
        ]
        if includeCaches {
            features["key_cache"] = MLFeatureValue(multiArray: keyCache)
            features["value_cache"] = MLFeatureValue(multiArray: valueCache)
        }
        return try MLDictionaryFeatureProvider(dictionary: features)
    }

    private static func fillDeterministic(_ array: MLMultiArray, scale: Float) {
        let pointer = array.dataPointer.assumingMemoryBound(to: UInt16.self)
        for index in 0..<array.count {
            let value = Float16(sinf(Float(index) * 0.0137) * scale)
            pointer[index] = value.bitPattern
        }
    }
}

private extension Duration {
    nonisolated var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
