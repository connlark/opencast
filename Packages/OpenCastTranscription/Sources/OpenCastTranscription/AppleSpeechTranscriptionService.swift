#if canImport(AVFoundation) && canImport(CoreMedia) && canImport(Speech)
import AVFoundation
import CoreMedia
import Foundation
import Speech

@available(macOS 26.0, iOS 26.0, visionOS 26.0, tvOS 26.0, *)
@available(watchOS, unavailable)
public actor AppleSpeechTranscriptionService {
    public static let modelIdentifierPrefix = "apple-speech-transcriber"

    private let requiresInstalledAssets: Bool
    private let allowsAssetInstallation: Bool

    public init(
        requiresInstalledAssets: Bool = true,
        allowsAssetInstallation: Bool = false
    ) {
        self.requiresInstalledAssets = requiresInstalledAssets
        self.allowsAssetInstallation = allowsAssetInstallation
    }

    public nonisolated static func modelIdentifier(localeIdentifier: String) -> String {
        "\(modelIdentifierPrefix).\(localeIdentifier)"
    }

    public static func assetStatus(languageCode: String = "en") async -> AppleSpeechAssetStatus {
        let requestedLocale = Locale(identifier: languageCode)
        let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
        let installedLocales = await SpeechTranscriber.installedLocales
            .map(\.identifier)
            .sorted()
        let status: AssetInventory.Status?
        if let resolvedLocale {
            let transcriber = SpeechTranscriber(locale: resolvedLocale, preset: .timeIndexedProgressiveTranscription)
            status = await AssetInventory.status(forModules: [transcriber])
        } else {
            status = nil
        }

        return AppleSpeechAssetStatus(
            requestedLocaleIdentifier: requestedLocale.identifier,
            resolvedLocaleIdentifier: resolvedLocale?.identifier,
            transcriberAvailable: SpeechTranscriber.isAvailable,
            assetInventoryStatus: status?.benchmarkDescription,
            installedLocaleIdentifiers: installedLocales
        )
    }

    public nonisolated func transcribe(
        _ request: OpenCastLongFormTranscriptionRequest
    ) -> AsyncThrowingStream<OpenCastLongFormTranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performTranscribe(request, continuation: continuation)
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

    public func unload() async {
        await SpeechModels.endRetention()
    }

    private func performTranscribe(
        _ request: OpenCastLongFormTranscriptionRequest,
        continuation: AsyncThrowingStream<OpenCastLongFormTranscriptionEvent, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: request.audioFileURL.path) else {
            throw OpenCastTranscriptionError.audioFileNotFound(request.audioFileURL)
        }

        let resumeStart = request.resumeStart ?? 0
        guard resumeStart == 0 else {
            throw AppleSpeechTranscriptionError.resumeNotSupported(resumeStart)
        }

        let clock = ContinuousClock()
        let pipelineStart = clock.now

        let audioLoadStart = clock.now
        let audioFile = try AVAudioFile(forReading: request.audioFileURL)
        let audioDuration = Self.audioDuration(for: audioFile)
        let audioLoading = audioLoadStart.duration(to: clock.now).timeInterval
        guard audioDuration.isFinite, audioDuration > 0 else {
            throw OpenCastTranscriptionError.invalidAudioDuration(audioDuration)
        }

        let preparationStart = clock.now
        let locale = try await Self.resolvedLocale(languageCode: request.languageCode)
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        try await prepareAssets(for: transcriber, locale: locale)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        )
        try await analyzer.prepareToAnalyze(in: audioFile.processingFormat)
        let modelLoading = preparationStart.duration(to: clock.now).timeInterval

        continuation.yield(.progress(OpenCastLongFormTranscriptionProgress(
            audioDuration: audioDuration,
            completedDuration: 0,
            checkpointCount: 0,
            currentWindowIndex: nil,
            currentText: nil
        )))

        let transcriptionStart = clock.now
        let collector = Task {
            try await Self.collectResults(
                from: transcriber,
                audioDuration: audioDuration,
                continuation: continuation
            )
        }

        do {
            // `analyzeSequence` does not reliably observe cooperative task
            // cancellation; without this handler a cancelled pass keeps the
            // Speech pipeline (and the app's CPU ledger) running to end of
            // file — in the background that trips the 80%/60s EXC_RESOURCE
            // kill once the continued-processing task is gone.
            try await withTaskCancellationHandler {
                _ = try await analyzer.analyzeSequence(from: audioFile)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                try Task.checkCancellation()
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            let accumulated = try await collector.value
            let transcription = transcriptionStart.duration(to: clock.now).timeInterval
            let fullPipeline = pipelineStart.duration(to: clock.now).timeInterval
            let segments = accumulated.orderedSegments()
            let text = Self.joinedText(from: segments)
            guard !segments.isEmpty, !text.isEmpty else {
                throw AppleSpeechTranscriptionError.noFinalTranscriptionResult
            }

            continuation.yield(.finished(OpenCastTranscriptionResult(
                modelIdentifier: Self.modelIdentifier(localeIdentifier: locale.identifier),
                languageCode: request.languageCode,
                text: text,
                segments: segments,
                timings: OpenCastTranscriptionTimings(
                    audioDuration: audioDuration,
                    modelLoading: modelLoading,
                    audioLoading: audioLoading,
                    transcription: transcription,
                    fullPipeline: fullPipeline,
                    realTimeFactor: transcription / audioDuration,
                    decodingFallbackCount: 0,
                    decodingFallback: 0,
                    decodingWindowCount: accumulated.finalResultCount
                )
            )))
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private func prepareAssets(
        for transcriber: SpeechTranscriber,
        locale: Locale
    ) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechTranscriptionError.transcriberUnavailable
        }

        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed:
            return
        case .unsupported:
            throw AppleSpeechTranscriptionError.unsupportedAssets(
                localeIdentifier: locale.identifier,
                status: status.benchmarkDescription
            )
        case .supported, .downloading:
            if requiresInstalledAssets {
                throw AppleSpeechTranscriptionError.assetsNotInstalled(
                    localeIdentifier: locale.identifier,
                    status: status.benchmarkDescription
                )
            }
            guard allowsAssetInstallation else {
                return
            }
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                throw AppleSpeechTranscriptionError.assetInstallationUnavailable(
                    localeIdentifier: locale.identifier,
                    status: status.benchmarkDescription
                )
            }
            try await request.downloadAndInstall()
        @unknown default:
            throw AppleSpeechTranscriptionError.unsupportedAssets(
                localeIdentifier: locale.identifier,
                status: status.benchmarkDescription
            )
        }
    }

    private static func collectResults(
        from transcriber: SpeechTranscriber,
        audioDuration: TimeInterval,
        continuation: AsyncThrowingStream<OpenCastLongFormTranscriptionEvent, Error>.Continuation
    ) async throws -> AppleSpeechResultAccumulator {
        var accumulator = AppleSpeechResultAccumulator()
        // Throttled background transcription streams a final result roughly
        // every spoken sentence, several per wall-second. Un-throttled, each
        // one fanned out into a full-document persist downstream (segment
        // normalize + JSON encode + file write, all O(transcript)), which
        // saturates the main thread as the transcript grows and trips the
        // background 80%/60s CPU kill. Checkpoints are UI/bookkeeping only
        // for Apple Speech (resume restarts from zero, decision 6), so a
        // coarse audio-time stride loses nothing.
        var throttle = AppleSpeechEventThrottle()
        for try await result in transcriber.results {
            try Task.checkCancellation()
            let progressText = plainText(from: result.text)
            let completedDuration = min(audioDuration, max(accumulator.completedDuration, endSeconds(for: result.range)))
            if throttle.shouldEmitProgress(at: completedDuration) {
                continuation.yield(.progress(OpenCastLongFormTranscriptionProgress(
                    audioDuration: audioDuration,
                    completedDuration: completedDuration,
                    checkpointCount: accumulator.finalResultCount,
                    currentWindowIndex: accumulator.finalResultCount,
                    currentText: progressText.isEmpty ? nil : progressText
                )))
            }

            guard result.isFinal else {
                accumulator.completedDuration = completedDuration
                continue
            }

            let nextSegments = mappedSegments(
                from: result.text,
                fallbackRange: result.range
            )
            accumulator.replaceSegments(in: result.range, with: nextSegments)

            guard throttle.shouldEmitCheckpoint(at: accumulator.completedDuration) else {
                continue
            }

            let segments = accumulator.orderedSegments()
            let text = joinedText(from: segments)
            continuation.yield(.checkpoint(OpenCastLongFormTranscriptionCheckpoint(
                index: accumulator.finalResultCount,
                audioDuration: audioDuration,
                completedDuration: min(audioDuration, max(completedDuration, accumulator.completedDuration)),
                segments: segments,
                text: text
            )))
        }
        return accumulator
    }

    static func mappedSegments(
        from attributedText: AttributedString,
        fallbackRange: CMTimeRange,
        startingAt idStart: Int = 0
    ) -> [OpenCastTranscriptSegment] {
        var wordSegments: [OpenCastTranscriptSegment] = []
        for run in attributedText.runs {
            let text = String(attributedText.characters[run.range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }

            let timeRange = run.audioTimeRange ?? fallbackRange
            guard let bounds = secondsBounds(for: timeRange), bounds.end > bounds.start else {
                continue
            }

            let words: [OpenCastTranscriptWord]? = if run.audioTimeRange != nil {
                [OpenCastTranscriptWord(start: bounds.start, end: bounds.end, text: text)]
            } else {
                nil
            }
            wordSegments.append(OpenCastTranscriptSegment(
                id: idStart + wordSegments.count,
                start: bounds.start,
                end: bounds.end,
                text: text,
                avgLogProbability: run.transcriptionConfidence ?? 0,
                noSpeechProbability: 0,
                words: words
            ))
        }

        if wordSegments.isEmpty {
            let text = plainText(from: attributedText)
            if let bounds = secondsBounds(for: fallbackRange), bounds.end > bounds.start, !text.isEmpty {
                wordSegments.append(OpenCastTranscriptSegment(
                    id: idStart,
                    start: bounds.start,
                    end: bounds.end,
                    text: text,
                    avgLogProbability: 0,
                    noSpeechProbability: 0
                ))
            }
        }

        return coalescedSegments(wordSegments, startingAt: idStart)
    }

    static func coalescedSegments(
        _ segments: [OpenCastTranscriptSegment],
        startingAt idStart: Int = 0
    ) -> [OpenCastTranscriptSegment] {
        var output: [OpenCastTranscriptSegment] = []
        output.reserveCapacity(segments.count)
        var group = AppleSpeechSegmentGroup()

        for segment in segments.sorted(by: segmentSort) {
            guard segment.start.isFinite,
                  segment.end.isFinite,
                  segment.end > segment.start
            else {
                continue
            }

            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }

            var cleanSegment = segment
            cleanSegment.text = text
            if group.shouldStartNewSegment(beforeAppending: cleanSegment) {
                output.append(group.makeSegment(id: idStart + output.count))
                group = AppleSpeechSegmentGroup()
            }
            group.append(cleanSegment)
        }

        if !group.isEmpty {
            output.append(group.makeSegment(id: idStart + output.count))
        }

        return output
    }

    private static func segmentSort(
        lhs: OpenCastTranscriptSegment,
        rhs: OpenCastTranscriptSegment
    ) -> Bool {
        if lhs.start == rhs.start {
            lhs.end < rhs.end
        } else {
            lhs.start < rhs.start
        }
    }

    private static func resolvedLocale(languageCode: String) async throws -> Locale {
        let requestedLocale = Locale(identifier: languageCode)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw AppleSpeechTranscriptionError.unsupportedLocale(requestedLocale.identifier)
        }
        return locale
    }

    private static func audioDuration(for audioFile: AVAudioFile) -> TimeInterval {
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else {
            return 0
        }
        return Double(audioFile.length) / sampleRate
    }

    fileprivate static func secondsBounds(for timeRange: CMTimeRange) -> (start: TimeInterval, end: TimeInterval)? {
        let start = timeRange.start.seconds
        let duration = timeRange.duration.seconds
        guard start.isFinite, duration.isFinite, duration >= 0 else {
            return nil
        }
        return (start, start + duration)
    }

    private static func endSeconds(for timeRange: CMTimeRange) -> TimeInterval {
        guard let bounds = secondsBounds(for: timeRange) else {
            return 0
        }
        return bounds.end
    }

    private static func plainText(from attributedText: AttributedString) -> String {
        String(attributedText.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func joinedText(from segments: [OpenCastTranscriptSegment]) -> String {
        segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Gates streamed-result fan-out by transcribed audio time. Strides are in
/// audio seconds, not wall seconds: background transcription chews through
/// several audio-seconds per wall-second, so these bound the event rate at
/// roughly progressStride/rtf and checkpointStride/rtf wall-seconds apart.
struct AppleSpeechEventThrottle {
    static let progressStride: TimeInterval = 5
    static let checkpointStride: TimeInterval = 60

    private var lastProgressDuration: TimeInterval?
    private var lastCheckpointDuration: TimeInterval?

    mutating func shouldEmitProgress(at completedDuration: TimeInterval) -> Bool {
        guard let lastProgressDuration else {
            self.lastProgressDuration = completedDuration
            return true
        }
        guard completedDuration - lastProgressDuration >= Self.progressStride else {
            return false
        }
        self.lastProgressDuration = completedDuration
        return true
    }

    mutating func shouldEmitCheckpoint(at completedDuration: TimeInterval) -> Bool {
        guard let lastCheckpointDuration else {
            self.lastCheckpointDuration = completedDuration
            return true
        }
        guard completedDuration - lastCheckpointDuration >= Self.checkpointStride else {
            return false
        }
        self.lastCheckpointDuration = completedDuration
        return true
    }
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, tvOS 26.0, *)
@available(watchOS, unavailable)
struct AppleSpeechResultAccumulator: Sendable {
    private var ranges: [AppleSpeechFinalRange] = []
    var completedDuration: TimeInterval = 0
    var finalResultCount = 0

    mutating func replaceSegments(in range: CMTimeRange, with segments: [OpenCastTranscriptSegment]) {
        guard let bounds = AppleSpeechTranscriptionService.secondsBounds(for: range) else {
            return
        }

        ranges.removeAll { $0.intersects(start: bounds.start, end: bounds.end) }
        ranges.append(AppleSpeechFinalRange(
            start: bounds.start,
            end: bounds.end,
            segments: segments
        ))
        completedDuration = max(completedDuration, bounds.end)
        finalResultCount += 1
    }

    func orderedSegments() -> [OpenCastTranscriptSegment] {
        ranges
            .sorted { lhs, rhs in
                if lhs.start == rhs.start {
                    lhs.end < rhs.end
                } else {
                    lhs.start < rhs.start
                }
            }
            .flatMap(\.segments)
            .sorted { lhs, rhs in
                if lhs.start == rhs.start {
                    lhs.end < rhs.end
                } else {
                    lhs.start < rhs.start
                }
            }
            .enumerated()
            .map { index, segment in
                var copy = segment
                copy.id = index
                return copy
            }
    }
}

struct AppleSpeechFinalRange: Sendable {
    // Adjacent final results share boundaries exactly; CMTime-to-seconds conversion
    // leaves ~1e-14s of float fuzz there. Anything below this tolerance is a touching
    // boundary, not a re-finalized range, and must not evict the earlier result.
    static let minimumMaterialOverlap: TimeInterval = 0.001

    var start: TimeInterval
    var end: TimeInterval
    var segments: [OpenCastTranscriptSegment]

    func intersects(start otherStart: TimeInterval, end otherEnd: TimeInterval) -> Bool {
        min(end, otherEnd) - max(start, otherStart) > Self.minimumMaterialOverlap
    }
}

private struct AppleSpeechSegmentGroup: Sendable {
    private static let maxGap: TimeInterval = 0.85
    private static let maxDuration: TimeInterval = 8
    private static let maxWordCount = 28
    private static let maxCharacterCount = 180
    private static let terminalCharacters = CharacterSet(charactersIn: ".?!")

    private var start: TimeInterval = 0
    private var end: TimeInterval = 0
    private var parts: [String] = []
    private var words: [OpenCastTranscriptWord] = []
    private var hasCompleteWordCoverage = true
    private var weightedConfidenceTotal: Double = 0
    private var weightedNoSpeechTotal: Double = 0
    private var weightTotal: Double = 0
    private var wordCount = 0
    private var characterCount = 0

    var isEmpty: Bool {
        parts.isEmpty
    }

    mutating func append(_ segment: OpenCastTranscriptSegment) {
        let segmentWordCount = Self.wordCount(in: segment.text)
        let segmentCharacterCount = segment.text.count
        let weight = max(segment.end - segment.start, 0.01)

        if isEmpty {
            start = segment.start
            end = segment.end
        } else {
            end = max(end, segment.end)
        }

        parts.append(segment.text)
        if let segmentWords = segment.words {
            words.append(contentsOf: segmentWords)
        } else {
            hasCompleteWordCoverage = false
        }
        weightedConfidenceTotal += segment.avgLogProbability * weight
        weightedNoSpeechTotal += segment.noSpeechProbability * weight
        weightTotal += weight
        wordCount += segmentWordCount
        characterCount += segmentCharacterCount
    }

    func shouldStartNewSegment(beforeAppending segment: OpenCastTranscriptSegment) -> Bool {
        guard !isEmpty else {
            return false
        }

        let gap = segment.start - end
        let proposedDuration = max(end, segment.end) - start
        let proposedWordCount = wordCount + Self.wordCount(in: segment.text)
        let proposedCharacterCount = characterCount + segment.text.count + 1

        return gap > Self.maxGap
            || hasTerminalBoundary
            || proposedDuration > Self.maxDuration
            || proposedWordCount > Self.maxWordCount
            || proposedCharacterCount > Self.maxCharacterCount
    }

    func makeSegment(id: Int) -> OpenCastTranscriptSegment {
        OpenCastTranscriptSegment(
            id: id,
            start: start,
            end: end,
            text: Self.joinedText(parts),
            avgLogProbability: weightTotal > 0 ? weightedConfidenceTotal / weightTotal : 0,
            noSpeechProbability: weightTotal > 0 ? weightedNoSpeechTotal / weightTotal : 0,
            words: hasCompleteWordCoverage && !words.isEmpty ? words : nil
        )
    }

    private var hasTerminalBoundary: Bool {
        guard let lastScalar = parts.last?.unicodeScalars.last else {
            return false
        }
        return Self.terminalCharacters.contains(lastScalar)
    }

    private static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func joinedText(_ parts: [String]) -> String {
        parts.reduce(into: "") { result, part in
            guard !part.isEmpty else {
                return
            }
            if result.isEmpty || part.unicodeScalars.allSatisfy(Self.isAttachedPunctuation) {
                result += part
            } else {
                result += " " + part
            }
        }
    }

    private static func isAttachedPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet(charactersIn: ".,;:!?)]}%").contains(scalar)
    }
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, tvOS 26.0, *)
@available(watchOS, unavailable)
private extension AssetInventory.Status {
    var benchmarkDescription: String {
        switch self {
        case .unsupported:
            "unsupported"
        case .supported:
            "supported"
        case .downloading:
            "downloading"
        case .installed:
            "installed"
        @unknown default:
            "unknown"
        }
    }
}
#endif
