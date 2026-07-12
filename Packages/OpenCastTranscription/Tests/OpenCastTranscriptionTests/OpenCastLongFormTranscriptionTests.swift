import Foundation
@testable import OpenCastTranscription
import Testing
@preconcurrency import WhisperKit

@Suite("OpenCast long-form transcription")
struct OpenCastLongFormTranscriptionTests {
    @Test("Long-form request accepts full episode durations")
    func longFormRequestAcceptsFullEpisodeDurations() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        let service = OpenCastTranscriptionService(
            modelLocator: RecordingModelLocator(),
            runtimeLoader: RecordingRuntimeLoader(log: TranscriptionEventLog()),
            audioLoader: ImmediateAudioLoader(samples: Array(repeating: 0.1, count: Int(WhisperKit.sampleRate) * 180))
        )
        let request = OpenCastLongFormTranscriptionRequest(
            audioFileURL: audioURL,
            sourceAudioURL: "https://example.com/audio.mp3",
            sourceFileByteCount: 10,
            sourceFileSHA256: "source-sha",
            modelIdentifier: "model-a",
            modelVersion: "v1",
            modelTreeSHA256: "tree-sha"
        )

        var didFinish = false
        for try await event in await service.transcribe(request) {
            if case .finished(let result) = event {
                didFinish = true
                #expect(result.timings.audioDuration == 180)
            }
        }

        #expect(didFinish)
    }

    @Test("Long-form finished result exports phase timings")
    func longFormFinishedResultExportsPhaseTimings() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        var timings = TranscriptionTimings(totalDecodingLoops: 7, totalDecodingWindows: 2)
        timings.inputAudioSeconds = 10
        let canned = TranscriptionResult(
            text: " hello",
            segments: [TranscriptionSegment(text: " hello", tokens: [1, 2])],
            language: "en",
            timings: timings
        )
        let service = OpenCastTranscriptionService(
            modelLocator: RecordingModelLocator(),
            runtimeLoader: FixedResultRuntimeLoader(result: canned),
            audioLoader: ImmediateAudioLoader(samples: Array(repeating: 0.1, count: Int(WhisperKit.sampleRate) * 10))
        )
        let request = OpenCastLongFormTranscriptionRequest(
            audioFileURL: audioURL,
            sourceAudioURL: "https://example.com/audio.mp3",
            sourceFileByteCount: 10,
            sourceFileSHA256: "source-sha",
            modelIdentifier: "model-a",
            modelVersion: "v1",
            modelTreeSHA256: "tree-sha"
        )

        var finishedPhases: OpenCastTranscriptionPhaseTimings?
        for try await event in await service.transcribe(request) {
            if case .finished(let result) = event {
                finishedPhases = result.timings.phases
            }
        }

        let phases = try #require(finishedPhases)
        #expect(phases.inputAudioSeconds == 10)
        #expect(phases.decodingLoopCount == 7)
        #expect(phases.windowCount == 2)
        #expect(phases.outputTokenCount == 2)
    }

    @Test("No-resume long-form run keeps full-duration RTF denominators")
    func noResumeLongFormRunKeepsFullDurationRTFDenominators() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        var timings = TranscriptionTimings(fullPipeline: 2)
        timings.inputAudioSeconds = 100
        let canned = TranscriptionResult(
            text: " hello",
            segments: [TranscriptionSegment(text: " hello", tokens: [1])],
            language: "en",
            timings: timings
        )
        let service = OpenCastTranscriptionService(
            modelLocator: RecordingModelLocator(),
            runtimeLoader: FixedResultRuntimeLoader(result: canned),
            audioLoader: ImmediateAudioLoader(samples: Array(repeating: 0.1, count: Int(WhisperKit.sampleRate) * 100))
        )
        let request = OpenCastLongFormTranscriptionRequest(
            audioFileURL: audioURL,
            sourceAudioURL: "https://example.com/audio.mp3",
            sourceFileByteCount: 10,
            sourceFileSHA256: "source-sha",
            modelIdentifier: "model-a",
            modelVersion: "v1",
            modelTreeSHA256: "tree-sha"
        )

        var finished: OpenCastTranscriptionResult?
        for try await event in await service.transcribe(request) {
            if case .finished(let result) = event {
                finished = result
            }
        }

        let result = try #require(finished)
        #expect(result.timings.audioDuration == 100)
        #expect(result.timings.processedAudioDuration == 100)
        #expect(abs(result.timings.realTimeFactor - result.timings.transcription / 100) < 0.000001)
        #expect(abs(result.timings.transcriptionRTF - result.timings.realTimeFactor) < 0.000001)
        #expect(abs(result.timings.fullPipelineRTF - result.timings.fullPipeline / 100) < 0.000001)
    }

    @Test("Resumed long-form run uses processed remaining duration for RTF")
    func resumedLongFormRunUsesProcessedRemainingDurationForRTF() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        var timings = TranscriptionTimings(fullPipeline: 2)
        timings.inputAudioSeconds = 40
        let canned = TranscriptionResult(
            text: " hello",
            segments: [TranscriptionSegment(text: " hello", tokens: [1])],
            language: "en",
            timings: timings
        )
        let service = OpenCastTranscriptionService(
            modelLocator: RecordingModelLocator(),
            runtimeLoader: FixedResultRuntimeLoader(result: canned),
            audioLoader: ImmediateAudioLoader(samples: Array(repeating: 0.1, count: Int(WhisperKit.sampleRate) * 100))
        )
        let request = OpenCastLongFormTranscriptionRequest(
            audioFileURL: audioURL,
            resumeStart: 60,
            sourceAudioURL: "https://example.com/audio.mp3",
            sourceFileByteCount: 10,
            sourceFileSHA256: "source-sha",
            modelIdentifier: "model-a",
            modelVersion: "v1",
            modelTreeSHA256: "tree-sha"
        )

        var finished: OpenCastTranscriptionResult?
        for try await event in await service.transcribe(request) {
            if case .finished(let result) = event {
                finished = result
            }
        }

        let result = try #require(finished)
        #expect(result.timings.audioDuration == 100)
        #expect(result.timings.processedAudioDuration == 40)
        #expect(abs(result.timings.realTimeFactor - result.timings.transcription / 40) < 0.000001)
        #expect(abs(result.timings.transcriptionRTF - result.timings.realTimeFactor) < 0.000001)
        #expect(abs(result.timings.fullPipelineRTF - result.timings.fullPipeline / 40) < 0.000001)
    }

    @Test("Long-form decode options keep fallback enabled and use sequential checkpoints")
    func longFormDecodeOptionsKeepFallbackEnabledAndUseSequentialCheckpoints() {
        let options = OpenCastTranscriptionService.longFormDecodeOptions(
            languageCode: "en",
            audioDuration: 600,
            resumeStart: 120
        )

        #expect(options.temperatureFallbackCount > 0)
        #expect(options.temperatureIncrementOnFallback > 0)
        #expect(options.chunkingStrategy == nil)
        #expect(options.clipTimestamps == [120, 600])
    }

    @Test("Long-form decode options honor a benchmark clip end")
    func longFormDecodeOptionsHonorBenchmarkClipEnd() {
        let options = OpenCastTranscriptionService.longFormDecodeOptions(
            languageCode: "en",
            audioDuration: 600,
            resumeStart: 30,
            clipEnd: 90
        )

        #expect(options.clipTimestamps == [30, 90])

        let clamped = OpenCastTranscriptionService.longFormDecodeOptions(
            languageCode: "en",
            audioDuration: 600,
            resumeStart: 0,
            clipEnd: 900
        )

        #expect(clamped.clipTimestamps == [0, 600])
    }

    @Test("Long-form stream emits progress checkpoint and final events")
    func longFormStreamEmitsProgressCheckpointAndFinalEvents() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        let service = OpenCastTranscriptionService(
            modelLocator: RecordingModelLocator(),
            runtimeLoader: RecordingRuntimeLoader(log: TranscriptionEventLog()),
            audioLoader: ImmediateAudioLoader(samples: Array(repeating: 0.1, count: Int(WhisperKit.sampleRate) * 10))
        )
        let request = OpenCastLongFormTranscriptionRequest(
            audioFileURL: audioURL,
            resumeStart: 3,
            sourceAudioURL: "https://example.com/audio.mp3",
            sourceFileByteCount: 10,
            sourceFileSHA256: "source-sha",
            modelIdentifier: "model-a",
            modelVersion: "v1",
            modelTreeSHA256: "tree-sha"
        )

        var sawProgress = false
        var sawWindowIndex = false
        var sawCheckpoint = false
        var sawFinished = false
        for try await event in await service.transcribe(request) {
            switch event {
            case .progress(let progress):
                sawProgress = true
                #expect(progress.audioDuration == 10)
                if progress.currentWindowIndex == 0 {
                    sawWindowIndex = true
                }
            case .checkpoint(let checkpoint):
                sawCheckpoint = true
                #expect(checkpoint.completedDuration >= 4)
                #expect(checkpoint.segments.first?.start == 3)
            case .finished(let result):
                sawFinished = true
                #expect(result.segments.first?.start == 3)
            }
        }

        #expect(sawProgress)
        #expect(sawWindowIndex)
        #expect(sawCheckpoint)
        #expect(sawFinished)
    }

    @Test("Optional large-v3 long-form interruption and resume probe")
    func optionalLargeV3LongFormInterruptionAndResumeProbe() async throws {
        guard ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPTION_RUN_LARGE_V3_LONGFORM"] == "1",
              let audioPath = ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPTION_AUDIO"] else {
            return
        }

        let audioURL = URL(fileURLWithPath: audioPath)
        let sourceFileByteCount = try fileByteCount(at: audioURL)
        let sourceFileSHA256 = try OpenCastSHA256.hashFile(at: audioURL)
        let service = OpenCastTranscriptionService()
        let request = OpenCastLongFormTranscriptionRequest(
            audioFileURL: audioURL,
            sourceAudioURL: audioURL.absoluteString,
            sourceFileByteCount: sourceFileByteCount,
            sourceFileSHA256: sourceFileSHA256,
            modelIdentifier: OpenCastWhisperModel.largeV3.rawValue,
            modelVersion: OpenCastWhisperModel.largeV3.defaultRemoteVersion,
            modelTreeSHA256: "receipt-backed"
        )

        let firstStart = ContinuousClock().now
        var interruptedCheckpoint: OpenCastLongFormTranscriptionCheckpoint?
        for try await event in await service.transcribe(request) {
            if case .checkpoint(let checkpoint) = event {
                interruptedCheckpoint = checkpoint
                break
            }
        }
        let interruptionElapsed = firstStart.duration(to: ContinuousClock().now).timeInterval
        try await Task.sleep(for: .milliseconds(250))

        let checkpoint = try #require(interruptedCheckpoint)
        let resumeRequest = OpenCastLongFormTranscriptionRequest(
            audioFileURL: audioURL,
            resumeStart: checkpoint.completedDuration,
            sourceAudioURL: audioURL.absoluteString,
            sourceFileByteCount: sourceFileByteCount,
            sourceFileSHA256: sourceFileSHA256,
            modelIdentifier: OpenCastWhisperModel.largeV3.rawValue,
            modelVersion: OpenCastWhisperModel.largeV3.defaultRemoteVersion,
            modelTreeSHA256: "receipt-backed"
        )

        let resumeStart = ContinuousClock().now
        var finalResult: OpenCastTranscriptionResult?
        var checkpointCount = 0
        for try await event in await service.transcribe(resumeRequest) {
            switch event {
            case .checkpoint:
                checkpointCount += 1
            case .finished(let result):
                finalResult = result
            case .progress:
                break
            }
        }
        await service.unload()

        let result = try #require(finalResult)
        let resumeElapsed = resumeStart.duration(to: ContinuousClock().now).timeInterval
        let report = """
        OpenCast large-v3 long-form probe
        audio_path=\(audioPath)
        audio_bytes=\(sourceFileByteCount)
        audio_duration_seconds=\(result.timings.audioDuration)
        first_checkpoint_completed_seconds=\(checkpoint.completedDuration)
        interruption_elapsed_seconds=\(interruptionElapsed)
        resume_elapsed_seconds=\(resumeElapsed)
        full_pipeline_seconds=\(result.timings.fullPipeline)
        real_time_factor=\(result.timings.realTimeFactor)
        checkpoint_count_after_resume=\(checkpointCount)
        resumed_from_checkpoint=true
        peak_memory=not measured by this test harness
        """
        print(report)

        #expect(!result.text.isEmpty)
        #expect(result.modelIdentifier == OpenCastWhisperModel.largeV3.rawValue)
        #expect(result.timings.audioDuration > checkpoint.completedDuration)
    }

    private func temporaryAudioPlaceholder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("wav")
        try Data("not audio".utf8).write(to: url)
        return url
    }

    private func fileByteCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        return Int64(values.fileSize ?? 0)
    }
}
