import Foundation
import Testing
@testable import OpenCastTranscription
@preconcurrency import WhisperKit

/// Opt-in real-model probe proving the word-timestamps path still produces
/// word timings after alignment accumulation became conditional (B2).
/// Requires the Tiny model installed locally and
/// OPENCAST_ALIGNMENT_PROBE=1 OPENCAST_TRANSCRIPTION_AUDIO=<file>.
@Suite("Alignment path probe")
struct AlignmentPathProbeTests {
    @Test(
        "Word timestamps still work with conditional alignment accumulation",
        .enabled(if: ProcessInfo.processInfo.environment["OPENCAST_ALIGNMENT_PROBE"] == "1"
            && ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPTION_AUDIO"] != nil)
    )
    func wordTimestampsStillWork() async throws {
        let audioPath = try #require(ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPTION_AUDIO"])

        let location = try DownloadedWhisperModelLocator(model: .tinyEnglish).modelLocation()
        let config = WhisperKitConfig(
            modelFolder: location.modelFolder.path,
            tokenizerFolder: location.tokenizerFolder,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        let whisperKit = try await WhisperKit(config)
        let samples = try await AudioProcessorTranscriptionAudioLoader().samples(
            from: URL(fileURLWithPath: audioPath),
            clipStart: 0,
            clipDuration: 30
        )

        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            concurrentWorkerCount: 1,
            chunkingStrategy: nil
        )
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        await whisperKit.unloadModels()

        let merged = TranscriptionUtilities.mergeTranscriptionResults(results.map(Optional.some))
        #expect(!merged.text.isEmpty)
        let words = merged.segments.flatMap { $0.words ?? [] }
        #expect(!words.isEmpty, "word timestamps should be produced when the option is on")
        if let first = words.first, let last = words.last {
            #expect(first.start >= 0)
            #expect(last.end <= 31)
            #expect(first.start <= last.end)
        }
        print("ALIGNMENT_PROBE words=\(words.count) firstWord=\(words.first?.word ?? "-") text=\(merged.text.prefix(80))")
    }
}
