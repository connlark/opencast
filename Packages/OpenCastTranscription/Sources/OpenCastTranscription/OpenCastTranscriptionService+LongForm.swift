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

        // Whisper-perf G2: the episode's canonical PCM spills to a temp file
        // and windows are served from it, so peak memory no longer scales
        // with episode length. The file is removed on completion,
        // cancellation, and error alike.
        let audioLoadStart = clock.now
        let spillURL = Self.makeAudioSpillFileURL()
        defer { try? FileManager.default.removeItem(at: spillURL) }
        let sampleCount = try await audioLoader.spillSamples(
            from: request.audioFileURL,
            clipStart: 0,
            clipDuration: nil,
            to: spillURL
        )
        let audioLoading = audioLoadStart.duration(to: clock.now).timeInterval
        try Task.checkCancellation()
        guard sampleCount > 0 else {
            throw OpenCastTranscriptionError.emptyAudioClip(clipStart: 0, clipDuration: 0)
        }
        // Open the reader immediately: the held descriptor keeps the samples
        // readable even if the caches directory is purged during the model
        // load (unlink-with-open-fd), closing the skeptic-found gap.
        let audioSource = try PCMFileAudioSampleSource(fileURL: spillURL, expectedSampleCount: sampleCount)

        let audioDuration = Double(sampleCount) / Double(WhisperKit.sampleRate)
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
            clipEnd: request.clipEnd,
            sourceFileSHA256: request.sourceFileSHA256
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
            audioSource: audioSource,
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

    /// Whisper-perf G2: spill files live under Caches (purgeable, never
    /// backed up), one per in-flight long-form run. Normal removal happens in
    /// `performLongFormTranscribe`'s defer; files orphaned by a process kill
    /// are swept here once they are a day old (concurrent service instances
    /// may hold younger live spills, so age-gate rather than clearing).
    static func makeAudioSpillFileURL() -> URL {
        let directory = audioSpillDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sweepStaleAudioSpillFiles(in: directory)
        return directory.appending(path: "\(UUID().uuidString).pcm")
    }

    static func audioSpillDirectory() -> URL {
        URL.cachesDirectory.appending(
            path: "OpenCastTranscription/AudioSpill",
            directoryHint: .isDirectory
        )
    }

    private static func sweepStaleAudioSpillFiles(in directory: URL) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }
        let cutoff = Date.now.addingTimeInterval(-24 * 60 * 60)
        for file in contents {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
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
        summary["deterministicFallbackBaseSeed"] = options.deterministicFallbackBaseSeed.map { String($0) } ?? "nil"
        return summary
    }

    static func longFormDecodeOptions(
        languageCode: String,
        audioDuration: TimeInterval,
        resumeStart: TimeInterval,
        clipEnd: TimeInterval? = nil,
        sourceFileSHA256: String? = nil
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
            chunkingStrategy: nil,
            deterministicFallbackBaseSeed: sourceFileSHA256.flatMap(Self.deterministicFallbackBaseSeed)
        )
        .withClipTimestamps(start: resumeStart, end: min(clipEnd ?? audioDuration, audioDuration))
    }

    /// Whisper-perf F: base seed from the leading 16 hex digits of the
    /// source audio SHA-256 — stable across runs and cancel/resume.
    static func deterministicFallbackBaseSeed(from sourceFileSHA256: String) -> UInt64? {
        let prefix = sourceFileSHA256.prefix(16)
        guard prefix.count == 16 else {
            return nil
        }
        return UInt64(prefix, radix: 16)
    }
}

private extension DecodingOptions {
    func withClipTimestamps(start: TimeInterval, end: TimeInterval) -> DecodingOptions {
        var copy = self
        copy.clipTimestamps = [Float(start), Float(end)]
        return copy
    }
}
