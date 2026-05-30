import Darwin
import Foundation
import OpenCastVoiceBoost

public enum VoiceBoostLab {
    public static func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            throw LabError.invalidArguments("Missing command.")
        }

        switch command {
        case "fixtures":
            let output = try requiredOptionValue("--output", in: arguments)
            try FixtureFactory.writeFixtures(to: URL(fileURLWithPath: output))
        case "analyze":
            guard arguments.count >= 2 else {
                throw LabError.invalidArguments("Missing input WAV.")
            }
            let input = URL(fileURLWithPath: arguments[1])
            let output = try requiredOptionValue("--output", in: arguments)
            let audio = try WAVFile.read(input)
            try JSONFile.write(AudioMetrics.make(audio: audio), to: URL(fileURLWithPath: output))
        case "process":
            guard arguments.count >= 2 else {
                throw LabError.invalidArguments("Missing input WAV.")
            }
            let input = URL(fileURLWithPath: arguments[1])
            let presetName = optionValue("--preset", in: arguments) ?? "default"
            let output = try requiredOptionValue("--output", in: arguments)
            let outputDirectory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let audio = try WAVFile.read(input)
            let preset = try VoiceBoostPreset(labName: presetName)
            let result = LabProcessor.process(
                audio,
                configuration: try configuration(from: arguments, base: preset.configuration)
            )
            try write(result, to: outputDirectory)
        case "listening-pack":
            guard arguments.count >= 2 else {
                throw LabError.invalidArguments("Missing input WAV.")
            }
            let input = URL(fileURLWithPath: arguments[1])
            let presetName = optionValue("--preset", in: arguments) ?? "default"
            let output = try requiredOptionValue("--output", in: arguments)
            let outputDirectory = URL(fileURLWithPath: output)
            let audio = try WAVFile.read(input)
            let referenceAudio = try optionValue("--reference", in: arguments).map {
                try WAVFile.read(URL(fileURLWithPath: $0))
            }
            let preset = try VoiceBoostPreset(labName: presetName)
            let result = try ListeningPack.make(
                audio: audio,
                referenceAudio: referenceAudio,
                configuration: try configuration(from: arguments, base: preset.configuration),
                toggleIntervalSeconds: try doubleOption("--toggle-interval", in: arguments) ?? 4
            )
            try ListeningPack.write(result, inputURL: input, to: outputDirectory)
        case "validate-listening-pack":
            guard arguments.count >= 2 else {
                throw LabError.invalidArguments("Missing listening pack directory.")
            }
            let packDirectory = URL(fileURLWithPath: arguments[1])
            let output = try requiredOptionValue("--output", in: arguments)
            let result = try ListeningPackValidator.validate(packDirectory: packDirectory)
            try JSONFile.write(result, to: URL(fileURLWithPath: output))
            guard result.passed else {
                throw LabError.invalidArguments("Listening pack validation failed. See \(output).")
            }
        case "compare":
            guard arguments.count >= 3 else {
                throw LabError.invalidArguments("Missing input and output WAV files.")
            }
            let input = try WAVFile.read(URL(fileURLWithPath: arguments[1]))
            let outputAudio = try WAVFile.read(URL(fileURLWithPath: arguments[2]))
            let output = try requiredOptionValue("--output", in: arguments)
            let comparison = ComparisonMetrics(
                input: AudioMetrics.make(audio: input),
                output: AudioMetrics.make(audio: outputAudio)
            )
            try JSONFile.write(comparison, to: URL(fileURLWithPath: output))
        case "benchmark":
            let output = try requiredOptionValue("--output", in: arguments)
            let presetName = optionValue("--preset", in: arguments) ?? "default"
            let preset = try VoiceBoostPreset(labName: presetName)
            let metrics = try BenchmarkRunner.run(
                durationSeconds: try doubleOption("--duration", in: arguments) ?? 600,
                sampleRate: try doubleOption("--sample-rate", in: arguments) ?? 48_000,
                channelCount: try intOption("--channels", in: arguments) ?? 2,
                blockFrameCount: try intOption("--block-frames", in: arguments) ?? 1_024,
                configuration: try configuration(from: arguments, base: preset.configuration)
            )
            try JSONFile.write(metrics, to: URL(fileURLWithPath: output))
        default:
            throw LabError.invalidArguments("Unknown command: \(command)")
        }
    }

    private static func requiredOptionValue(_ option: String, in arguments: [String]) throws -> String {
        guard let value = optionValue(option, in: arguments) else {
            throw LabError.invalidArguments("Missing \(option).")
        }
        return value
    }

    private static func write(_ result: ProcessResult, to outputDirectory: URL) throws {
        try WAVFile.write(result.processedAudio, to: outputDirectory.appending(path: "processed.wav"))
        try JSONFile.write(result.inputMetrics, to: outputDirectory.appending(path: "input_metrics.json"))
        try JSONFile.write(result.outputMetrics, to: outputDirectory.appending(path: "output_metrics.json"))
        try JSONFile.write(result.comparisonMetrics, to: outputDirectory.appending(path: "comparison.json"))
        try result.timeline.csvString().write(
            to: outputDirectory.appending(path: "timeline.csv"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func optionValue(_ option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func configuration(
        from arguments: [String],
        base: VoiceBoostConfiguration
    ) throws -> VoiceBoostConfiguration {
        var configuration = base
        configuration.targetLUFS = try doubleOption("--target-lufs", in: arguments) ?? configuration.targetLUFS
        configuration.truePeakCeilingDBTP = try doubleOption("--ceiling-dbtp", in: arguments)
            ?? configuration.truePeakCeilingDBTP
        configuration.maximumPositiveGainDB = try doubleOption("--max-gain-db", in: arguments)
            ?? configuration.maximumPositiveGainDB
        configuration.maximumNegativeGainDB = try doubleOption("--min-gain-db", in: arguments)
            ?? configuration.maximumNegativeGainDB
        if arguments.contains("--no-adaptive-gain") {
            configuration.usesAdaptiveGain = false
        }
        if arguments.contains("--no-eq") {
            configuration.usesEqualization = false
        }
        if arguments.contains("--no-compression") {
            configuration.usesCompression = false
        }
        return configuration
    }

    private static func doubleOption(_ option: String, in arguments: [String]) throws -> Double? {
        guard let value = optionValue(option, in: arguments) else {
            return nil
        }
        guard let parsed = Double(value), parsed.isFinite else {
            throw LabError.invalidArguments("Invalid \(option): \(value)")
        }
        return parsed
    }

    private static func intOption(_ option: String, in arguments: [String]) throws -> Int? {
        guard let value = optionValue(option, in: arguments) else {
            return nil
        }
        guard let parsed = Int(value) else {
            throw LabError.invalidArguments("Invalid \(option): \(value)")
        }
        return parsed
    }

    public static let usage = """

    Usage:
      VoiceBoostLab fixtures --output out/fixtures
      VoiceBoostLab analyze input.wav --output out/input_metrics.json
      VoiceBoostLab process input.wav --preset default --output out/
      VoiceBoostLab listening-pack input.wav --preset default --output out/listening/
      VoiceBoostLab listening-pack input.wav --reference reference.wav --preset default --output out/listening/
      VoiceBoostLab validate-listening-pack out/listening/ --output out/validation.json
      VoiceBoostLab compare input.wav out/processed.wav --output out/comparison.json
      VoiceBoostLab benchmark --duration 600 --output out/benchmark.json

    Presets:
      limiterOnly, transparent, default, clarity, loud

    Process overrides:
      --target-lufs -14
      --ceiling-dbtp -1
      --max-gain-db 12
      --min-gain-db -10
      --no-adaptive-gain
      --no-eq
      --no-compression

    Listening-pack options:
      --reference reference.wav
      --toggle-interval 4

    Benchmark options:
      --duration 600
      --sample-rate 48000
      --channels 2
      --block-frames 1024

    WAV support:
      16-bit PCM and 32-bit float WAV, mono or stereo.

    """
}
