import Foundation
@preconcurrency import WhisperKit

public actor OpenCastTranscriptionService {
    let modelLocator: any OpenCastWhisperModelLocating
    private let runtimeLoader: any OpenCastTranscriptionRuntimeLoading
    let audioLoader: any OpenCastTranscriptionAudioLoading
    private var operationTail: Task<Void, Never>?
    private var runtime: (modelIdentifier: String, runtime: any OpenCastTranscriptionRuntime)?
    private var loadedModelIdentifier: String?

    public init(
        modelLocator: any OpenCastWhisperModelLocating = DownloadedWhisperModelLocator(),
        computeProfile: OpenCastTranscriptionComputeProfile = .backgroundSafe
    ) {
        self.init(
            modelLocator: modelLocator,
            runtimeLoader: WhisperKitTranscriptionRuntimeLoader(computeProfile: computeProfile),
            audioLoader: AudioProcessorTranscriptionAudioLoader()
        )
    }

    init(
        modelLocator: any OpenCastWhisperModelLocating = DownloadedWhisperModelLocator(),
        runtimeLoader: any OpenCastTranscriptionRuntimeLoading,
        audioLoader: any OpenCastTranscriptionAudioLoading
    ) {
        self.modelLocator = modelLocator
        self.runtimeLoader = runtimeLoader
        self.audioLoader = audioLoader
    }

    public func transcribe(_ request: OpenCastTranscriptionRequest) async throws -> OpenCastTranscriptionResult {
        try await enqueueOperation {
            try await self.performTranscribe(request)
        }
    }

    public func unload() async {
        try? await enqueueOperation {
            await self.performUnload()
        }
    }

    func enqueueOperation<Result: Sendable>(
        _ operation: @Sendable @escaping () async throws -> Result
    ) async throws -> Result {
        let previousOperation = operationTail
        let currentOperation = Task {
            if let previousOperation {
                await previousOperation.value
            }

            try Task.checkCancellation()
            return try await operation()
        }

        operationTail = Task {
            _ = try? await currentOperation.value
        }

        return try await withTaskCancellationHandler {
            try await currentOperation.value
        } onCancel: {
            currentOperation.cancel()
        }
    }

    private func performTranscribe(_ request: OpenCastTranscriptionRequest) async throws -> OpenCastTranscriptionResult {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: request.audioFileURL.path) else {
            throw OpenCastTranscriptionError.audioFileNotFound(request.audioFileURL)
        }

        let clipStart = request.clipStart
        let clipDuration = request.clipDuration
        guard clipStart.isFinite, clipStart >= 0 else {
            throw OpenCastTranscriptionError.invalidClipStart(clipStart)
        }
        guard clipDuration.isFinite, clipDuration > 0, clipDuration <= OpenCastTranscriptionRequest.maximumClipDuration else {
            throw OpenCastTranscriptionError.invalidClipDuration(clipDuration)
        }

        let clock = ContinuousClock()
        let pipelineStart = clock.now

        let audioLoadStart = clock.now
        let samples = try await audioLoader.samples(
            from: request.audioFileURL,
            clipStart: clipStart,
            clipDuration: clipDuration
        )
        let audioLoading = audioLoadStart.duration(to: clock.now).timeInterval
        try Task.checkCancellation()
        guard !samples.isEmpty else {
            throw OpenCastTranscriptionError.emptyAudioClip(clipStart: clipStart, clipDuration: clipDuration)
        }

        let location = try modelLocator.modelLocation()
        let (runtime, modelLoading) = try await runtime(for: location, clock: clock)

        let decodeOptions = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: request.languageCode,
            temperature: 0,
            temperatureIncrementOnFallback: 0,
            temperatureFallbackCount: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            concurrentWorkerCount: 1,
            chunkingStrategy: nil
        )

        let transcriptionStart = clock.now
        let transcriptions = try await runtime.transcribe(
            audioArray: samples,
            decodeOptions: decodeOptions,
            callback: nil,
            windowCallback: nil,
            segmentCallback: nil
        )
        let transcription = transcriptionStart.duration(to: clock.now).timeInterval
        guard !transcriptions.isEmpty else {
            throw OpenCastTranscriptionError.noTranscriptionResult
        }

        let merged = TranscriptionUtilities.mergeTranscriptionResults(transcriptions.map(Optional.some))
        let fullPipeline = pipelineStart.duration(to: clock.now).timeInterval
        let audioDuration = Double(samples.count) / Double(WhisperKit.sampleRate)

        return OpenCastTranscriptionResult(
            modelIdentifier: location.modelIdentifier,
            languageCode: request.languageCode,
            text: merged.text.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: mappedSegments(from: merged.segments, clipStart: clipStart),
            timings: OpenCastTranscriptionTimings(
                audioDuration: audioDuration,
                modelLoading: modelLoading,
                audioLoading: audioLoading,
                transcription: transcription,
                fullPipeline: fullPipeline,
                realTimeFactor: transcription / audioDuration,
                decodingFallbackCount: Int(merged.timings.totalDecodingFallbacks),
                decodingFallback: merged.timings.decodingFallback,
                decodingWindowCount: Int(merged.timings.totalDecodingWindows),
                phases: Self.phaseTimings(from: merged)
            )
        )
    }

    nonisolated static func phaseTimings(from merged: TranscriptionResult) -> OpenCastTranscriptionPhaseTimings {
        OpenCastTranscriptionPhaseTimings(
            timings: merged.timings,
            outputTokenCount: merged.segments.reduce(0) { $0 + $1.tokens.count }
        )
    }

    func performUnload() async {
        await runtime?.runtime.unloadModels()
        runtime = nil
        loadedModelIdentifier = nil
    }

    func runtime(
        for location: OpenCastWhisperModelLocation,
        clock: ContinuousClock
    ) async throws -> (any OpenCastTranscriptionRuntime, TimeInterval) {
        if let runtime, loadedModelIdentifier == location.modelIdentifier {
            return (runtime.runtime, 0)
        }

        await performUnload()
        try Task.checkCancellation()

        let loadStart = clock.now
        let runtime = try await runtimeLoader.loadRuntime(for: location)
        try Task.checkCancellation()
        let modelLoading = loadStart.duration(to: clock.now).timeInterval
        self.runtime = (location.modelIdentifier, runtime)
        loadedModelIdentifier = location.modelIdentifier
        return (runtime, modelLoading)
    }

    nonisolated func mappedSegments(
        from segments: [TranscriptionSegment],
        clipStart: TimeInterval
    ) -> [OpenCastTranscriptSegment] {
        segments.enumerated().map { index, segment in
            Self.mappedSegment(segment, id: index, clipStart: clipStart)
        }
    }

    nonisolated func mappedSegment(_ segment: TranscriptionSegment, id: Int) -> OpenCastTranscriptSegment {
        Self.mappedSegment(segment, id: id, clipStart: 0)
    }

    nonisolated static func mappedSegment(
        _ segment: TranscriptionSegment,
        id: Int,
        clipStart: TimeInterval = 0
    ) -> OpenCastTranscriptSegment {
        let bounds = globalBounds(for: segment)
        return OpenCastTranscriptSegment(
            id: id,
            start: bounds.start + clipStart,
            end: bounds.end + clipStart,
            text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
            avgLogProbability: Double(segment.avgLogprob),
            noSpeechProbability: Double(segment.noSpeechProb)
        )
    }

    nonisolated private static func globalBounds(for segment: TranscriptionSegment) -> (start: TimeInterval, end: TimeInterval) {
        let start = TimeInterval(segment.start)
        let end = TimeInterval(segment.end)
        let seekStart = TimeInterval(segment.seek) / TimeInterval(WhisperKit.sampleRate)
        let timestampOffsetTolerance = 0.05
        if seekStart > 0,
           start + timestampOffsetTolerance < seekStart,
           end + timestampOffsetTolerance < seekStart {
            return (start + seekStart, end + seekStart)
        }
        return (start, end)
    }
}
