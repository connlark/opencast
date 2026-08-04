import Foundation
@testable import OpenCastTranscription
import Testing
@preconcurrency import WhisperKit

@Suite("OpenCast transcription service")
struct OpenCastTranscriptionServiceTests {
    @Test("Request defaults bound transcription to a short clip")
    func requestDefaultsBoundTranscriptionToShortClip() {
        let request = OpenCastTranscriptionRequest(audioFileURL: URL(fileURLWithPath: "/tmp/audio.wav"))

        #expect(request.clipStart == 0)
        #expect(request.clipDuration == OpenCastTranscriptionRequest.defaultClipDuration)
        #expect(OpenCastTranscriptionRequest.defaultClipDuration < OpenCastTranscriptionRequest.maximumClipDuration)
    }

    @Test("Invalid clip duration fails before model load")
    func invalidClipDurationFailsBeforeModelLoad() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        let locator = RecordingModelLocator()
        let service = OpenCastTranscriptionService(
            modelLocator: locator,
            runtimeLoader: RecordingRuntimeLoader(log: TranscriptionEventLog()),
            audioLoader: ImmediateAudioLoader(samples: oneSecondSamples())
        )
        let request = OpenCastTranscriptionRequest(
            audioFileURL: audioURL,
            clipDuration: OpenCastTranscriptionRequest.maximumClipDuration + 1
        )

        do {
            _ = try await service.transcribe(request)
            Issue.record("Expected invalid clip duration to throw")
        } catch OpenCastTranscriptionError.invalidClipDuration {
        } catch {
            Issue.record("Expected invalid clip duration, got \(error)")
        }
        #expect(locator.callCount == 0)
    }

    @Test("Invalid clip start fails before model load")
    func invalidClipStartFailsBeforeModelLoad() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        let locator = RecordingModelLocator()
        let service = OpenCastTranscriptionService(
            modelLocator: locator,
            runtimeLoader: RecordingRuntimeLoader(log: TranscriptionEventLog()),
            audioLoader: ImmediateAudioLoader(samples: oneSecondSamples())
        )
        let request = OpenCastTranscriptionRequest(
            audioFileURL: audioURL,
            clipStart: -1
        )

        do {
            _ = try await service.transcribe(request)
            Issue.record("Expected invalid clip start to throw")
        } catch OpenCastTranscriptionError.invalidClipStart {
        } catch {
            Issue.record("Expected invalid clip start, got \(error)")
        }
        #expect(locator.callCount == 0)
    }

    @Test("Empty clips fail before model load")
    func emptyClipsFailBeforeModelLoad() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        let locator = RecordingModelLocator()
        let service = OpenCastTranscriptionService(
            modelLocator: locator,
            runtimeLoader: RecordingRuntimeLoader(log: TranscriptionEventLog()),
            audioLoader: ImmediateAudioLoader(samples: [])
        )

        do {
            _ = try await service.transcribe(OpenCastTranscriptionRequest(audioFileURL: audioURL))
            Issue.record("Expected empty audio clip to throw")
        } catch OpenCastTranscriptionError.emptyAudioClip {
        } catch {
            Issue.record("Expected empty audio clip, got \(error)")
        }
        #expect(locator.callCount == 0)
    }

    @Test("Transcription reports requested language and decode RTF")
    func transcriptionReportsRequestedLanguageAndDecodeRTF() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        let log = TranscriptionEventLog()
        let service = OpenCastTranscriptionService(
            modelLocator: RecordingModelLocator(),
            runtimeLoader: RecordingRuntimeLoader(log: log),
            audioLoader: ImmediateAudioLoader(samples: oneSecondSamples())
        )

        let result = try await service.transcribe(
            OpenCastTranscriptionRequest(
                audioFileURL: audioURL,
                languageCode: "en"
            )
        )

        #expect(result.languageCode == "en")
        #expect(result.timings.audioDuration == 1)
        #expect(result.timings.transcription > 0)
        #expect(result.timings.fullPipeline >= result.timings.transcription)
        #expect(abs(result.timings.realTimeFactor - result.timings.transcription) < 0.001)
    }

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

    @Test("Default service reports missing downloaded large v3")
    func defaultServiceReportsMissingDownloadedLargeV3() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        let installStore = OpenCastWhisperModelInstallStore(
            rootDirectory: FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)
                .appending(path: "TranscriptionModels")
        )
        let service = OpenCastTranscriptionService(
            modelLocator: DownloadedWhisperModelLocator(installStore: installStore),
            runtimeLoader: RecordingRuntimeLoader(log: TranscriptionEventLog()),
            audioLoader: ImmediateAudioLoader(samples: oneSecondSamples())
        )

        do {
            _ = try await service.transcribe(OpenCastTranscriptionRequest(audioFileURL: audioURL))
            Issue.record("Expected missing downloaded large-v3 to throw")
        } catch let error as OpenCastTranscriptionError {
            #expect(
                error == .modelNotInstalled(
                    modelIdentifier: OpenCastWhisperModel.largeV3.rawValue,
                    version: OpenCastWhisperModel.largeV3.defaultRemoteVersion
                )
            )
        } catch {
            Issue.record("Expected modelNotInstalled, got \(error)")
        }
    }

    @Test("Explicit tiny injection still transcribes through provided runtime")
    func explicitTinyInjectionStillTranscribesThroughProvidedRuntime() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        let service = OpenCastTranscriptionService(
            modelLocator: RecordingModelLocator(modelIdentifier: OpenCastWhisperModel.tinyEnglish.rawValue),
            runtimeLoader: RecordingRuntimeLoader(log: TranscriptionEventLog()),
            audioLoader: ImmediateAudioLoader(samples: oneSecondSamples())
        )

        let result = try await service.transcribe(OpenCastTranscriptionRequest(audioFileURL: audioURL))

        #expect(result.modelIdentifier == OpenCastWhisperModel.tinyEnglish.rawValue)
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

    @Test("Phase timings are exported from the runtime result")
    func phaseTimingsAreExportedFromRuntimeResult() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        var timings = TranscriptionTimings(
            modelLoading: 1.5,
            encoderLoadTime: 0.7,
            decoderLoadTime: 0.6,
            tokenizerLoadTime: 0.2,
            audioProcessing: 0.25,
            logmels: 0.5,
            encoding: 0.75,
            decodingInit: 0.1,
            decodingLoop: 4.0,
            decodingPredictions: 2.0,
            decodingFiltering: 0.6,
            decodingSampling: 0.3,
            decodingFallback: 0.2,
            decodingWindowing: 0.15,
            decodingKvCaching: 0.4,
            decodingTimestampAlignment: 0.05,
            decodingNonPrediction: 1.9,
            totalAudioProcessingRuns: 3,
            totalLogmelRuns: 3,
            totalEncodingRuns: 3,
            totalDecodingLoops: 42,
            totalKVUpdateRuns: 40,
            totalTimestampAlignmentRuns: 1,
            totalDecodingFallbacks: 2,
            totalDecodingWindows: 3,
            fullPipeline: 5.5
        )
        timings.inputAudioSeconds = 30
        timings.pipelineStart = 100
        timings.firstTokenTime = 100.8
        let canned = TranscriptionResult(
            text: " hello world",
            segments: [
                TranscriptionSegment(text: " hello", tokens: [1, 2, 3]),
                TranscriptionSegment(text: " world", tokens: [4, 5]),
            ],
            language: "en",
            timings: timings
        )
        let service = OpenCastTranscriptionService(
            modelLocator: RecordingModelLocator(),
            runtimeLoader: FixedResultRuntimeLoader(result: canned),
            audioLoader: ImmediateAudioLoader(samples: oneSecondSamples())
        )

        let result = try await service.transcribe(OpenCastTranscriptionRequest(audioFileURL: audioURL))

        let phases = try #require(result.timings.phases)
        #expect(phases.inputAudioSeconds == 30)
        #expect(phases.modelLoading == 1.5)
        #expect(phases.encoderLoadTime == 0.7)
        #expect(phases.decoderLoadTime == 0.6)
        #expect(phases.tokenizerLoadTime == 0.2)
        #expect(phases.audioProcessing == 0.25)
        #expect(phases.logmels == 0.5)
        #expect(phases.encoding == 0.75)
        #expect(phases.decodingInit == 0.1)
        #expect(phases.decodingLoop == 4.0)
        #expect(phases.decodingPredictions == 2.0)
        #expect(phases.decodingFiltering == 0.6)
        #expect(phases.decodingSampling == 0.3)
        #expect(phases.decodingFallback == 0.2)
        #expect(phases.decodingWindowing == 0.15)
        #expect(phases.decodingKvCaching == 0.4)
        #expect(phases.decodingWordTimestamps == 0.05)
        #expect(phases.decodingNonPrediction == 1.9)
        #expect(phases.fullPipeline == 5.5)
        #expect(phases.audioProcessingRunCount == 3)
        #expect(phases.logmelRunCount == 3)
        #expect(phases.encodingRunCount == 3)
        #expect(phases.decodingLoopCount == 42)
        #expect(phases.kvUpdateRunCount == 40)
        #expect(phases.timestampAlignmentRunCount == 1)
        #expect(phases.fallbackCount == 2)
        #expect(phases.windowCount == 3)
        #expect(phases.outputTokenCount == 5)
        let timeToFirstToken = try #require(phases.timeToFirstToken)
        #expect(abs(timeToFirstToken - 0.8) < 0.0001)
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
