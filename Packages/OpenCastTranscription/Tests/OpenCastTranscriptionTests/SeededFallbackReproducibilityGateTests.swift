import CryptoKit
import Foundation
import Testing
@testable import OpenCastTranscription
@preconcurrency import WhisperKit

/// F gate (whisper-perf pass 2): with deterministic fallback seeding, two
/// same-build full-episode runs — product decode options, fallback retries
/// ENABLED — must produce bit-identical tokens/segments/timestamps, and the
/// workload must actually exercise fallbacks (otherwise the gate is
/// vacuous). Unseeded runs of the same workload are nondeterministic on any
/// build (pass-1 evidence: 13 vs 6 fallbacks on identical binaries).
/// OPENCAST_F_GATE=1 OPENCAST_TRANSCRIPTION_AUDIO=<mp3>
@Suite("Seeded fallback reproducibility gate")
struct SeededFallbackReproducibilityGateTests {
    @Test(
        "Two seeded full-episode runs are bit-identical",
        .timeLimit(.minutes(30)),
        .enabled(if: ProcessInfo.processInfo.environment["OPENCAST_F_GATE"] == "1"
            && ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPTION_AUDIO"] != nil)
    )
    func seededRunsAreBitIdentical() async throws {
        let environment = ProcessInfo.processInfo.environment
        let audioPath = try #require(environment["OPENCAST_TRANSCRIPTION_AUDIO"])

        let audioData = try Data(contentsOf: URL(fileURLWithPath: audioPath))
        let sourceSHA = SHA256.hash(data: audioData).map { String(format: "%02x", $0) }.joined()

        // Whisper-perf pass 5 (Q3): OPENCAST_GATE_MODEL_VERSION selects a
        // sideloaded candidate tree; unset runs the shipped default.
        let location = try DownloadedWhisperModelLocator(
            model: .tinyEnglish,
            version: environment["OPENCAST_GATE_MODEL_VERSION"]
        ).modelLocation()
        let config = WhisperKitConfig(
            modelFolder: location.modelFolder.path,
            tokenizerFolder: location.tokenizerFolder,
            computeOptions: ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuOnly, textDecoderCompute: .cpuOnly),
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        let whisperKit = try await WhisperKit(config)
        // Whisper-perf G2: OPENCAST_GATE_AUDIO_SOURCE=windowed runs the
        // spilled-PCM source path against the same seeded reference sha.
        let useWindowedSource = environment["OPENCAST_GATE_AUDIO_SOURCE"] == "windowed"
        let spillURL = FileManager.default.temporaryDirectory
            .appending(path: "f-gate-spill-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: spillURL) }
        let audioSource: (any AudioSampleSource)?
        let sampleCount: Int
        var samples: [Float] = []
        if useWindowedSource {
            sampleCount = try await AudioProcessorTranscriptionAudioLoader().spillSamples(
                from: URL(fileURLWithPath: audioPath),
                clipStart: 0,
                clipDuration: nil,
                to: spillURL
            )
            audioSource = try PCMFileAudioSampleSource(fileURL: spillURL, expectedSampleCount: sampleCount)
        } else {
            samples = try await AudioProcessorTranscriptionAudioLoader().samples(
                from: URL(fileURLWithPath: audioPath),
                clipStart: 0,
                clipDuration: nil
            )
            sampleCount = samples.count
            audioSource = nil
        }
        let audioDuration = Double(sampleCount) / Double(WhisperKit.sampleRate)

        // Product options with fallback retries ENABLED. Seeded by default;
        // OPENCAST_F_GATE_MODE=unseeded runs the legacy nondeterministic
        // path (used to measure the unseeded spread for the WER gate).
        let unseeded = environment["OPENCAST_F_GATE_MODE"] == "unseeded"
        let options = OpenCastTranscriptionService.longFormDecodeOptions(
            languageCode: "en",
            audioDuration: audioDuration,
            resumeStart: 0,
            sourceFileSHA256: unseeded ? nil : sourceSHA
        )
        #expect(unseeded || options.deterministicFallbackBaseSeed != nil)
        let runCount = Int(environment["OPENCAST_F_GATE_RUNS"] ?? "") ?? 2
        let dumpDirectory = environment["OPENCAST_F_GATE_OUT_DIR"]

        var dumps: [String] = []
        var texts: [String] = []
        var segmentsPerRun: [[TranscriptionSegment]] = []
        var fallbackCounts: [Int] = []
        for _ in 0..<runCount {
            let results: [TranscriptionResult]
            if let audioSource {
                results = try await whisperKit.transcribe(audioSource: audioSource, decodeOptions: options)
            } else {
                results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
            }
            let merged = TranscriptionUtilities.mergeTranscriptionResults(results.map(Optional.some))
            segmentsPerRun.append(merged.segments)
            fallbackCounts.append(Int(merged.timings.totalDecodingFallbacks))
            let lines = merged.segments.map {
                "seg seek=\($0.seek) start=\($0.start.bitPattern) end=\($0.end.bitPattern) tokens=\($0.tokens.map(String.init).joined(separator: ",")) text=\($0.text)"
            }
            dumps.append(lines.joined(separator: "\n"))
            texts.append(merged.text)
        }
        await whisperKit.unloadModels()

        if let dumpDirectory {
            let directory = URL(fileURLWithPath: dumpDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let prefix = unseeded ? "unseeded" : "seeded"
            for (index, text) in texts.enumerated() {
                try Data(text.utf8).write(to: directory.appending(path: "\(prefix)-run\(index).txt"))
                try Data(dumps[index].utf8).write(to: directory.appending(path: "\(prefix)-run\(index)-dump.txt"))
                // Whisper-style JSON for the ad-zone harness.
                let whisperJSON: [String: Any] = [
                    "text": text,
                    "language": "en",
                    "segments": segmentsPerRun[index].enumerated().map { segmentIndex, segment in
                        ["id": segmentIndex, "start": Double(segment.start), "end": Double(segment.end), "text": segment.text] as [String: Any]
                    },
                ]
                let jsonData = try JSONSerialization.data(withJSONObject: whisperJSON)
                try jsonData.write(to: directory.appending(path: "\(prefix)-run\(index).json"))
            }
        }

        let allIdentical = dumps.allSatisfy { $0 == dumps[0] }
        print("F_GATE mode=\(unseeded ? "unseeded" : "seeded") runs=\(runCount) fallbacks=\(fallbackCounts) identical=\(allIdentical) sha=\(OpenCastSHA256.hash(Data(dumps[0].utf8)))")
        if !unseeded {
            #expect(allIdentical, "seeded runs must be bit-identical")
            // Whisper-perf pass 5: OPENCAST_F_GATE_ALLOW_ZERO=1 admits
            // content that decodes without fallbacks on this surface (the
            // 3-h stress episode and logfiles are zero-fallback on host);
            // the anchor keeps the strict non-vacuous default.
            if environment["OPENCAST_F_GATE_ALLOW_ZERO"] != "1" {
                #expect(fallbackCounts.allSatisfy { $0 > 0 }, "workload must exercise fallbacks or the gate is vacuous")
            }
            #expect(Set(fallbackCounts).count == 1)
        }
    }
}
