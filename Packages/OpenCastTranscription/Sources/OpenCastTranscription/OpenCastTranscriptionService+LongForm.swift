import Foundation
@preconcurrency import WhisperKit

public extension OpenCastTranscriptionService {
    func transcribe(
        _ request: OpenCastLongFormTranscriptionRequest
    ) -> AsyncThrowingStream<OpenCastLongFormTranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await enqueueOperation {
                        try await self.performLongFormTranscribe(request, continuation: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

extension OpenCastTranscriptionService {
    func performLongFormTranscribe(
        _ request: OpenCastLongFormTranscriptionRequest,
        continuation: AsyncThrowingStream<OpenCastLongFormTranscriptionEvent, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: request.audioFileURL.path) else {
            throw OpenCastTranscriptionError.audioFileNotFound(request.audioFileURL)
        }

        let resumeStart = request.resumeStart ?? 0
        guard resumeStart.isFinite, resumeStart >= 0 else {
            throw OpenCastTranscriptionError.invalidResumeStart(resumeStart)
        }

        let clock = ContinuousClock()
        let pipelineStart = clock.now

        let audioLoadStart = clock.now
        let samples = try await audioLoader.samples(
            from: request.audioFileURL,
            clipStart: 0,
            clipDuration: nil
        )
        let audioLoading = audioLoadStart.duration(to: clock.now).timeInterval
        try Task.checkCancellation()
        guard !samples.isEmpty else {
            throw OpenCastTranscriptionError.emptyAudioClip(clipStart: 0, clipDuration: 0)
        }

        let audioDuration = Double(samples.count) / Double(WhisperKit.sampleRate)
        guard audioDuration.isFinite, audioDuration > 0 else {
            throw OpenCastTranscriptionError.invalidAudioDuration(audioDuration)
        }
        guard resumeStart < audioDuration else {
            throw OpenCastTranscriptionError.invalidResumeStart(resumeStart)
        }
        if let clipEnd = request.clipEnd {
            guard clipEnd.isFinite, clipEnd > resumeStart else {
                throw OpenCastTranscriptionError.invalidClipDuration(clipEnd - resumeStart)
            }
        }

        let location = try modelLocator.modelLocation()
        let (runtime, modelLoading) = try await runtime(for: location, clock: clock)
        let decodeOptions = Self.longFormDecodeOptions(
            languageCode: request.languageCode,
            audioDuration: audioDuration,
            resumeStart: resumeStart,
            clipEnd: request.clipEnd
        )
        let emitter = OpenCastLongFormTranscriptionEventEmitter(
            continuation: continuation,
            audioDuration: audioDuration,
            resumeStart: resumeStart,
            segmentMapper: { segment, id in
                OpenCastTranscriptionService.mappedSegment(segment, id: id)
            }
        )
        emitter.yieldInitialProgress()

        let transcriptionStart = clock.now
        // Production passes no per-token hypothesis callback: the once-per-window
        // signal supplies currentWindowIndex and cancellation propagates through
        // task cancellation inside the decode loop.
        let transcriptions = try await runtime.transcribe(
            audioArray: samples,
            decodeOptions: decodeOptions,
            callback: nil,
            windowCallback: { windowIndex in
                emitter.handleWindowStart(windowIndex)
            },
            segmentCallback: { segments in
                emitter.handleSegments(segments)
            }
        )
        let transcription = transcriptionStart.duration(to: clock.now).timeInterval
        guard !transcriptions.isEmpty else {
            throw OpenCastTranscriptionError.noTranscriptionResult
        }

        let merged = TranscriptionUtilities.mergeTranscriptionResults(transcriptions.map(Optional.some))
        let fullPipeline = pipelineStart.duration(to: clock.now).timeInterval
        // WhisperKit's inputAudioSeconds already excludes the resumed prefix
        // (contentFrames / sampleRate - clipTimestamps.first).
        let processedAudioDuration = merged.timings.inputAudioSeconds
        let result = OpenCastTranscriptionResult(
            modelIdentifier: location.modelIdentifier,
            languageCode: request.languageCode,
            text: merged.text.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: mappedSegments(from: merged.segments, clipStart: 0),
            timings: OpenCastTranscriptionTimings(
                audioDuration: audioDuration,
                processedAudioDuration: processedAudioDuration,
                modelLoading: modelLoading,
                audioLoading: audioLoading,
                transcription: transcription,
                fullPipeline: fullPipeline,
                realTimeFactor: processedAudioDuration > 0 ? transcription / processedAudioDuration : 0,
                decodingFallbackCount: Int(merged.timings.totalDecodingFallbacks),
                decodingFallback: merged.timings.decodingFallback,
                decodingWindowCount: Int(merged.timings.totalDecodingWindows),
                phases: Self.phaseTimings(from: merged)
            )
        )
        continuation.yield(.finished(result))
    }

    /// Run-manifest snapshot of the actual long-form decode options, so
    /// benchmark artifacts pin the decode configuration they measured.
    public static func longFormDecodeOptionsSummary(
        languageCode: String,
        audioDuration: TimeInterval,
        resumeStart: TimeInterval,
        clipEnd: TimeInterval? = nil
    ) -> [String: String] {
        let options = longFormDecodeOptions(
            languageCode: languageCode,
            audioDuration: audioDuration,
            resumeStart: resumeStart,
            clipEnd: clipEnd
        )
        var summary: [String: String] = [:]
        summary["task"] = "transcribe"
        summary["language"] = options.language ?? "nil"
        summary["temperature"] = String(options.temperature)
        summary["temperatureIncrementOnFallback"] = String(options.temperatureIncrementOnFallback)
        summary["temperatureFallbackCount"] = String(options.temperatureFallbackCount)
        summary["sampleLength"] = String(options.sampleLength)
        summary["topK"] = String(options.topK)
        summary["usePrefillPrompt"] = String(options.usePrefillPrompt)
        summary["detectLanguage"] = String(options.detectLanguage)
        summary["skipSpecialTokens"] = String(options.skipSpecialTokens)
        summary["withoutTimestamps"] = String(options.withoutTimestamps)
        summary["wordTimestamps"] = String(options.wordTimestamps)
        summary["clipTimestamps"] = options.clipTimestamps.map { String($0) }.joined(separator: ",")
        summary["windowClipTime"] = String(options.windowClipTime)
        summary["suppressBlank"] = String(options.suppressBlank)
        summary["compressionRatioThreshold"] = options.compressionRatioThreshold.map { String($0) } ?? "nil"
        summary["logProbThreshold"] = options.logProbThreshold.map { String($0) } ?? "nil"
        summary["firstTokenLogProbThreshold"] = options.firstTokenLogProbThreshold.map { String($0) } ?? "nil"
        summary["noSpeechThreshold"] = options.noSpeechThreshold.map { String($0) } ?? "nil"
        summary["concurrentWorkerCount"] = String(options.concurrentWorkerCount)
        summary["chunkingStrategy"] = options.chunkingStrategy.map { String(describing: $0) } ?? "nil"
        return summary
    }

    static func longFormDecodeOptions(
        languageCode: String,
        audioDuration: TimeInterval,
        resumeStart: TimeInterval,
        clipEnd: TimeInterval? = nil
    ) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: languageCode,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            concurrentWorkerCount: 1,
            chunkingStrategy: nil
        )
        .withClipTimestamps(start: resumeStart, end: min(clipEnd ?? audioDuration, audioDuration))
    }
}

private extension DecodingOptions {
    func withClipTimestamps(start: TimeInterval, end: TimeInterval) -> DecodingOptions {
        var copy = self
        copy.clipTimestamps = [Float(start), Float(end)]
        return copy
    }
}
