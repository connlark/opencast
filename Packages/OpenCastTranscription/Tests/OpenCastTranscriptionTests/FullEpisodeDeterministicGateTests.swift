import Foundation
import Testing
@testable import OpenCastTranscription
@preconcurrency import WhisperKit

/// Opt-in full-episode deterministic exact-output gate. Runs the product
/// long-form decode options with fallbacks disabled (fallback retries sample
/// at temperature > 0 with unseeded randomness, so any fallback makes
/// full-episode output nondeterministic on every build). Writes a canonical
/// token/segment dump for cross-build diffing.
/// OPENCAST_FULL_GATE=1 OPENCAST_TRANSCRIPTION_AUDIO=<mp3>
/// OPENCAST_FULL_GATE_OUT=<output file>
@Suite("Full episode deterministic gate")
struct FullEpisodeDeterministicGateTests {
    @Test("Zero-fallback full episode transcript dump", .timeLimit(.minutes(30)))
    func zeroFallbackFullEpisodeTranscriptDump() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENCAST_FULL_GATE"] == "1",
              let audioPath = environment["OPENCAST_TRANSCRIPTION_AUDIO"],
              let outPath = environment["OPENCAST_FULL_GATE_OUT"] else {
            return
        }

        let location = try DownloadedWhisperModelLocator(model: .tinyEnglish).modelLocation()
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
        let samples = try await AudioProcessorTranscriptionAudioLoader().samples(
            from: URL(fileURLWithPath: audioPath),
            clipStart: 0,
            clipDuration: nil
        )
        let audioDuration = Double(samples.count) / Double(WhisperKit.sampleRate)

        var options = OpenCastTranscriptionService.longFormDecodeOptions(
            languageCode: "en",
            audioDuration: audioDuration,
            resumeStart: 0
        )
        // Deterministic: no fallback retries, so every token is temp-0 argmax.
        options.temperatureFallbackCount = 0

        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        await whisperKit.unloadModels()
        let merged = TranscriptionUtilities.mergeTranscriptionResults(results.map(Optional.some))

        var lines: [String] = []
        lines.append("audioDuration=\(audioDuration)")
        lines.append("windows=\(Int(merged.timings.totalDecodingWindows)) fallbacks=\(Int(merged.timings.totalDecodingFallbacks))")
        for segment in merged.segments {
            lines.append("seg seek=\(segment.seek) start=\(segment.start.bitPattern) end=\(segment.end.bitPattern) tokens=\(segment.tokens.map(String.init).joined(separator: ",")) text=\(segment.text)")
        }
        let dump = lines.joined(separator: "\n")
        try Data(dump.utf8).write(to: URL(fileURLWithPath: outPath))
        print("FULL_GATE segments=\(merged.segments.count) tokens=\(merged.segments.reduce(0) { $0 + $1.tokens.count }) fallbacks=\(Int(merged.timings.totalDecodingFallbacks)) sha=\(OpenCastSHA256.hash(Data(dump.utf8)))")
        #expect(!merged.segments.isEmpty)
    }
}
