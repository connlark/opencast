import Foundation
@testable import OpenCastTranscription
import Testing
@preconcurrency import WhisperKit

@Suite("OpenCast transcription service")
struct OpenCastTranscriptionServiceTests {
    @Test("Overlapping transcribes serialize model load and decode")
    func overlappingTranscribesSerializeModelLoadAndDecode() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        let log = TranscriptionEventLog()
        let loader = RecordingRuntimeLoader(
            log: log,
            loadDelay: .milliseconds(40),
            decodeDelay: .milliseconds(40)
        )
        let service = OpenCastTranscriptionService(
            modelLocator: RecordingModelLocator(),
            runtimeLoader: loader,
            audioLoader: ImmediateAudioLoader(samples: oneSecondSamples())
        )
        let request = OpenCastTranscriptionRequest(audioFileURL: audioURL)

        async let first = service.transcribe(request)
        async let second = service.transcribe(request)
        _ = try await (first, second)

        #expect(await loader.loadCount(for: "model-a") == 1)
        #expect(await loader.maxActiveLoadCount == 1)
        let runtime = await loader.runtime(for: "model-a")
        #expect(await runtime?.maxActiveDecodeCount == 1)
        #expect(await runtime?.decodeCount == 2)
    }

    @Test("Unload waits for active transcription")
    func unloadWaitsForActiveTranscription() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        let log = TranscriptionEventLog()
        let service = OpenCastTranscriptionService(
            modelLocator: RecordingModelLocator(),
            runtimeLoader: RecordingRuntimeLoader(
                log: log,
                decodeDelay: .milliseconds(80)
            ),
            audioLoader: ImmediateAudioLoader(samples: oneSecondSamples())
        )

        async let transcription = service.transcribe(OpenCastTranscriptionRequest(audioFileURL: audioURL))
        #expect(await log.waitForPrefix("decode-start:model-a"))
        await service.unload()
        _ = try await transcription

        let events = await log.snapshot()
        let decodeEnd = events.firstIndex { $0.hasPrefix("decode-end:model-a") }
        let unload = events.firstIndex(of: "unload:model-a")
        #expect(decodeEnd != nil)
        #expect(unload != nil)
        #expect(unload! > decodeEnd!)
    }

    @Test("Model switching does not start parallel loads")
    func modelSwitchingDoesNotStartParallelLoads() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        let log = TranscriptionEventLog()
        let locator = RecordingModelLocator(modelIdentifier: "model-a")
        let loader = RecordingRuntimeLoader(
            log: log,
            loadDelay: .milliseconds(80),
            decodeDelay: .milliseconds(30)
        )
        let service = OpenCastTranscriptionService(
            modelLocator: locator,
            runtimeLoader: loader,
            audioLoader: ImmediateAudioLoader(samples: oneSecondSamples())
        )
        let request = OpenCastTranscriptionRequest(audioFileURL: audioURL)

        async let first = service.transcribe(request)
        #expect(await log.waitForPrefix("load-start:model-a"))
        locator.updateModelIdentifier("model-b")
        async let second = service.transcribe(request)
        _ = try await (first, second)

        #expect(await loader.loadCount(for: "model-a") == 1)
        #expect(await loader.loadCount(for: "model-b") == 1)
        #expect(await loader.maxActiveLoadCount == 1)

        let events = await log.snapshot()
        let firstDecodeEnd = events.firstIndex { $0.hasPrefix("decode-end:model-a") }
        let secondLoadStart = events.firstIndex(of: "load-start:model-b")
        #expect(firstDecodeEnd != nil)
        #expect(secondLoadStart != nil)
        #expect(secondLoadStart! > firstDecodeEnd!)
    }

    @Test("Segment mapping preserves already global seek timestamps")
    func segmentMappingPreservesAlreadyGlobalSeekTimestamps() {
        let seekStart = 3317.2
        let seek = Int(seekStart * Double(WhisperKit.sampleRate))
        let segment = TranscriptionSegment(
            seek: seek,
            start: Float(seekStart - 0.02),
            end: Float(seekStart + 5.9),
            text: " already global"
        )

        let mapped = OpenCastTranscriptionService.mappedSegment(segment, id: 7)

        #expect(mapped.id == 7)
        #expect(abs(mapped.start - Double(segment.start)) < 0.001)
        #expect(abs(mapped.end - Double(segment.end)) < 0.001)
        #expect(mapped.end > mapped.start)
    }

    @Test("Segment mapping offsets genuinely local seek timestamps")
    func segmentMappingOffsetsGenuinelyLocalSeekTimestamps() {
        let seek = Int(120 * Double(WhisperKit.sampleRate))
        let seekStart = Double(seek) / Double(WhisperKit.sampleRate)
        let segment = TranscriptionSegment(
            seek: seek,
            start: 0.5,
            end: 1.5,
            text: " local"
        )

        let mapped = OpenCastTranscriptionService.mappedSegment(segment, id: 8)

        #expect(abs(mapped.start - (seekStart + 0.5)) < 0.001)
        #expect(abs(mapped.end - (seekStart + 1.5)) < 0.001)
    }

    @Test("Segment mapping avoids partial offset for seek-boundary straddles")
    func segmentMappingAvoidsPartialOffsetForSeekBoundaryStraddles() {
        let seekStart = 120.0
        let seek = Int(seekStart * Double(WhisperKit.sampleRate))
        let segment = TranscriptionSegment(
            seek: seek,
            start: 0.5,
            end: Float(seekStart + 0.1),
            text: " straddles seek boundary"
        )

        let mapped = OpenCastTranscriptionService.mappedSegment(segment, id: 9)

        #expect(mapped.id == 9)
        #expect(abs(mapped.start - 0.5) < 0.001)
        #expect(abs(mapped.end - (seekStart + 0.1)) < 0.001)
        #expect(mapped.end > mapped.start)
    }

    @Test(
        "Optional downloaded tiny-model transcription probe",
        .enabled(if: ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPTION_RUN_TINY"] == "1"
            && ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPTION_AUDIO"] != nil)
    )
    func optionalDownloadedTinyModelTranscriptionProbe() async throws {
        let audioPath = try #require(ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPTION_AUDIO"])

        let service = OpenCastTranscriptionService(
            modelLocator: DownloadedWhisperModelLocator(model: .tinyEnglish)
        )
        let result = try await service.transcribe(
            OpenCastTranscriptionRequest(
                audioFileURL: URL(fileURLWithPath: audioPath),
                clipDuration: 30,
                languageCode: "en"
            )
        )
        await service.unload()

        #expect(result.modelIdentifier == OpenCastWhisperModel.tinyEnglish.rawValue)
        #expect(!result.text.isEmpty)
        #expect(result.timings.audioDuration <= 30.1)
        print("OpenCast tiny transcription probe timings: \(result.timings)")
    }

    @Test(
        "Optional large-v3 transcription probe",
        .enabled(if: ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPTION_RUN_LARGE_V3"] == "1"
            && ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPTION_AUDIO"] != nil)
    )
    func optionalLargeV3TranscriptionProbe() async throws {
        let audioPath = try #require(ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPTION_AUDIO"])

        let service = OpenCastTranscriptionService()
        let result = try await service.transcribe(
            OpenCastTranscriptionRequest(
                audioFileURL: URL(fileURLWithPath: audioPath),
                clipDuration: 30,
                languageCode: "en"
            )
        )
        await service.unload()

        #expect(result.modelIdentifier == OpenCastWhisperModel.largeV3.rawValue)
        #expect(!result.text.isEmpty)
        #expect(result.timings.audioDuration <= 30.1)
        print("OpenCast large-v3 transcription probe timings: \(result.timings)")
    }

    @Test("Phase timings without a first token export no time to first token")
    func phaseTimingsWithoutFirstTokenExportNoTimeToFirstToken() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        let canned = TranscriptionResult(
            text: "",
            segments: [],
            language: "en",
            timings: TranscriptionTimings()
        )
        let service = OpenCastTranscriptionService(
            modelLocator: RecordingModelLocator(),
            runtimeLoader: FixedResultRuntimeLoader(result: canned),
            audioLoader: ImmediateAudioLoader(samples: oneSecondSamples())
        )

        let result = try await service.transcribe(OpenCastTranscriptionRequest(audioFileURL: audioURL))

        let phases = try #require(result.timings.phases)
        #expect(phases.timeToFirstToken == nil)
        #expect(phases.outputTokenCount == 0)
    }

    private func temporaryAudioPlaceholder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("wav")
        try Data("not audio".utf8).write(to: url)
        return url
    }

    private func oneSecondSamples() -> [Float] {
        Array(repeating: 0.1, count: Int(WhisperKit.sampleRate))
    }
}
