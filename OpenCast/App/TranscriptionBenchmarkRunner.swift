import Foundation
import OpenCastCore
import OpenCastTranscription
import UIKit

/// Quiet, Release-capable transcription benchmark harness.
///
/// Unlike the DEBUG proof runner, this writes no files while a transcription
/// is being timed: events are counted in memory and one report JSON is
/// written per lifecycle transition (manifest ready, run finished, done).
nonisolated struct TranscriptionBenchmarkRunner: Sendable {
    static let requestArgument = "--opencast-run-transcription-benchmark"
    static let requestEnvironmentKey = "OPENCAST_RUN_TRANSCRIPTION_BENCHMARK"
    static let feedURLArgument = "--opencast-benchmark-feed-url"
    static let feedURLEnvironmentKey = "OPENCAST_BENCHMARK_FEED_URL"
    static let episodeTitleArgument = "--opencast-benchmark-episode-title"
    static let episodeTitleEnvironmentKey = "OPENCAST_BENCHMARK_EPISODE_TITLE"
    static let modelArgument = "--opencast-benchmark-model"
    static let modelEnvironmentKey = "OPENCAST_BENCHMARK_MODEL"
    static let modelVersionArgument = "--opencast-benchmark-model-version"
    static let modelVersionEnvironmentKey = "OPENCAST_BENCHMARK_MODEL_VERSION"
    static let computeArgument = "--opencast-benchmark-compute"
    static let computeEnvironmentKey = "OPENCAST_BENCHMARK_COMPUTE"
    static let clipStartArgument = "--opencast-benchmark-clip-start"
    static let clipStartEnvironmentKey = "OPENCAST_BENCHMARK_CLIP_START"
    static let clipEndArgument = "--opencast-benchmark-clip-end"
    static let clipEndEnvironmentKey = "OPENCAST_BENCHMARK_CLIP_END"
    static let repeatsArgument = "--opencast-benchmark-repeats"
    static let repeatsEnvironmentKey = "OPENCAST_BENCHMARK_REPEATS"
    static let runLabelArgument = "--opencast-benchmark-run-label"
    static let runLabelEnvironmentKey = "OPENCAST_BENCHMARK_RUN_LABEL"
    static let installModelArgument = "--opencast-benchmark-install-model"
    static let installModelEnvironmentKey = "OPENCAST_BENCHMARK_INSTALL_MODEL"
    static let commitEnvironmentKey = "OPENCAST_BENCHMARK_COMMIT"
    static let notesEnvironmentKey = "OPENCAST_BENCHMARK_NOTES"

    private static let defaultFeedURL = URL(string: "https://feeds.feedburner.com/LibrivoxCommunityPodcast")!

    var feedURL: URL
    var preferredEpisodeTitle: String?
    var model: OpenCastWhisperModel
    var modelVersion: String?
    var computeProfile: OpenCastTranscriptionComputeProfile
    var clipStart: TimeInterval?
    var clipEnd: TimeInterval?
    var repeats: Int
    var runLabel: String?
    var commit: String?
    var notes: String?
    var installsModelIfNeeded: Bool

    @concurrent
    static func runIfRequested() async {
        let processInfo = ProcessInfo.processInfo
        let arguments = processInfo.arguments
        let environment = processInfo.environment

        // Whisper-perf I3: opt-in decoder microbench replaces the normal
        // benchmark for this launch (measure-only spike; no product path).
        if StatefulSpikeDecoderProbe.isRequested {
            await StatefulSpikeDecoderProbe.run(
                runLabel: BenchmarkHarnessSupport.argumentValue(from: arguments, flag: runLabelArgument) ?? environment[runLabelEnvironmentKey],
                commit: environment[commitEnvironmentKey]
            )
            return
        }

        let isRequested = arguments.contains(requestArgument)
            || environment[requestEnvironmentKey] == "1"
        guard isRequested else {
            return
        }

        func value(_ flag: String, _ environmentKey: String) -> String? {
            BenchmarkHarnessSupport.argumentValue(from: arguments, flag: flag) ?? environment[environmentKey]
        }

        let runner = TranscriptionBenchmarkRunner(
            feedURL: value(feedURLArgument, feedURLEnvironmentKey).flatMap(URL.init(string:)) ?? defaultFeedURL,
            preferredEpisodeTitle: value(episodeTitleArgument, episodeTitleEnvironmentKey),
            model: value(modelArgument, modelEnvironmentKey).flatMap(OpenCastWhisperModel.init(commandLineValue:)) ?? .tinyEnglish,
            modelVersion: value(modelVersionArgument, modelVersionEnvironmentKey),
            computeProfile: value(computeArgument, computeEnvironmentKey).flatMap(OpenCastTranscriptionComputeProfile.init(rawValue:)) ?? .backgroundSafe,
            clipStart: value(clipStartArgument, clipStartEnvironmentKey).flatMap(TimeInterval.init),
            clipEnd: value(clipEndArgument, clipEndEnvironmentKey).flatMap(TimeInterval.init),
            repeats: value(repeatsArgument, repeatsEnvironmentKey).flatMap(Int.init).map { max(1, $0) } ?? 1,
            runLabel: value(runLabelArgument, runLabelEnvironmentKey),
            commit: environment[commitEnvironmentKey],
            notes: environment[notesEnvironmentKey],
            installsModelIfNeeded: value(installModelArgument, installModelEnvironmentKey) == "1"
        )
        await runner.run()
    }

    @concurrent
    func run() async {
        await MainActor.run {
            UIApplication.shared.isIdleTimerDisabled = true
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        defer {
            Task { @MainActor in
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }

        var report = TranscriptionBenchmarkReport(
            feedURL: feedURL,
            languageCode: "en",
            requestedRepeats: repeats
        )
        report.runLabel = runLabel
        report.commit = commit
        report.notes = notes
        report.deviceModelIdentifier = BenchmarkHarnessSupport.machineIdentifier()
        report.systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        report.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        report.appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        report.modelIdentifier = model.rawValue
        report.modelVersion = modelVersion ?? model.defaultRemoteVersion
        report.computeProfile = computeProfile.logDescription
        report.clipStart = clipStart
        report.clipEnd = clipEnd

        let reportURL = Self.reportURL(runLabel: runLabel, startedAt: report.createdAt)
        do {
            try BenchmarkHarnessSupport.prepareReportDirectory(Self.benchmarkDirectory())

            let feed = try await DefaultFeedService().fetchFeed(at: feedURL)
            let episode = try Self.selectedEpisode(from: feed, preferredEpisodeTitle: preferredEpisodeTitle)
            guard let audioURL = episode.audioURL else {
                throw OpenCastCoreError.missingAudioURL
            }
            report.episodeTitle = episode.title
            report.episodeID = episode.id.rawValue
            report.sourceAudioURL = audioURL.absoluteString

            let modelSummary = try await Self.modelSummary(
                model: model,
                version: modelVersion,
                installsIfNeeded: installsModelIfNeeded
            )
            report.modelIdentifier = modelSummary.modelIdentifier
            report.modelVersion = modelSummary.version
            report.modelTreeSHA256 = modelSummary.treeSHA256
            report.modelByteCount = modelSummary.totalByteCount

            let audioFileURL = try await Self.downloadAudioIfNeeded(audioURL, episodeID: episode.id.rawValue)
            report.sourceFilePath = audioFileURL.path
            report.sourceFileByteCount = try Self.fileByteCount(at: audioFileURL)
            report.sourceFileSHA256 = try await OpenCastSHA256.hashFileOffCaller(at: audioFileURL)
            try BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)

            let request = OpenCastLongFormTranscriptionRequest(
                audioFileURL: audioFileURL,
                languageCode: report.languageCode,
                resumeStart: clipStart,
                clipEnd: clipEnd,
                sourceAudioURL: audioURL.absoluteString,
                sourceFileByteCount: report.sourceFileByteCount ?? 0,
                sourceFileSHA256: report.sourceFileSHA256 ?? "",
                modelIdentifier: modelSummary.modelIdentifier,
                modelVersion: modelSummary.version,
                modelTreeSHA256: modelSummary.treeSHA256
            )
            let service = OpenCastTranscriptionService(
                modelLocator: DownloadedWhisperModelLocator(model: model, version: modelVersion),
                computeProfile: computeProfile
            )

            var lastResult: OpenCastTranscriptionResult?
            for runIndex in 0..<repeats {
                let runResult = try await Self.performRun(
                    index: runIndex,
                    service: service,
                    request: request
                )
                report.runs.append(runResult.metrics)
                if report.decodeOptions == nil {
                    report.decodeOptions = OpenCastTranscriptionService.longFormDecodeOptionsSummary(
                        languageCode: report.languageCode,
                        audioDuration: runResult.result.timings.audioDuration,
                        resumeStart: clipStart ?? 0,
                        clipEnd: clipEnd
                    )
                }
                lastResult = runResult.result
                try BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)
            }
            await service.unload()

            if let lastResult {
                report.transcriptRelativePath = try await Self.writeTranscriptDocument(
                    result: lastResult,
                    episode: episode,
                    audioURL: audioURL,
                    audioByteCount: report.sourceFileByteCount ?? 0,
                    audioSHA256: report.sourceFileSHA256 ?? "",
                    modelVersion: modelSummary.version,
                    modelTreeSHA256: modelSummary.treeSHA256
                )
            }
            report.outputsIdenticalAcrossRuns = Set(report.runs.map { "\($0.textSHA256)|\($0.segmentsSHA256)" }).count <= 1
            report.status = "completed"
            report.completedAt = .now
            try BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)
        } catch {
            report.status = "failed"
            report.errorMessage = error.localizedDescription
            report.completedAt = .now
            try? BenchmarkHarnessSupport.prepareReportDirectory(Self.benchmarkDirectory())
            try? BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)
        }
    }

    private static func performRun(
        index: Int,
        service: OpenCastTranscriptionService,
        request: OpenCastLongFormTranscriptionRequest
    ) async throws -> (metrics: TranscriptionBenchmarkRunResult, result: OpenCastTranscriptionResult) {
        let startedAt = Date.now
        let thermalStart = BenchmarkHarnessSupport.thermalStateDescription
        let batteryStart = await batterySnapshot()
        let footprintStart = MemoryFootprintSampler.currentFootprintBytes()
        let footprintSampler = MemoryFootprintSampler()
        footprintSampler.start()

        var progressEventCount = 0
        var checkpointEventCount = 0
        var finishedResult: OpenCastTranscriptionResult?
        for try await event in await service.transcribe(request) {
            switch event {
            case .progress:
                progressEventCount += 1
            case .checkpoint:
                checkpointEventCount += 1
            case .finished(let result):
                finishedResult = result
            }
        }
        guard let result = finishedResult else {
            _ = footprintSampler.stop()
            throw OpenCastTranscriptionError.noTranscriptionResult
        }

        let footprintPeak = footprintSampler.stop()
        let footprintEnd = MemoryFootprintSampler.currentFootprintBytes()
        let batteryEnd = await batterySnapshot()
        let metrics = TranscriptionBenchmarkRunResult(
            index: index,
            startedAt: startedAt,
            finishedAt: .now,
            thermalStateStart: thermalStart,
            thermalStateEnd: BenchmarkHarnessSupport.thermalStateDescription,
            batteryLevelStart: batteryStart.level,
            batteryLevelEnd: batteryEnd.level,
            batteryStateStart: batteryStart.state,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            audioDuration: result.timings.audioDuration,
            processedAudioDuration: result.timings.processedAudioDuration,
            modelLoading: result.timings.modelLoading,
            audioLoading: result.timings.audioLoading,
            transcription: result.timings.transcription,
            fullPipeline: result.timings.fullPipeline,
            transcriptionRTF: result.timings.transcriptionRTF,
            fullPipelineRTF: result.timings.fullPipelineRTF,
            decodingWindowCount: result.timings.decodingWindowCount,
            decodingFallbackCount: result.timings.decodingFallbackCount,
            decodingFallback: result.timings.decodingFallback,
            phases: result.timings.phases,
            footprintStartBytes: footprintStart,
            footprintEndBytes: footprintEnd,
            footprintPeakSampledBytes: footprintPeak,
            progressEventCount: progressEventCount,
            checkpointEventCount: checkpointEventCount,
            segmentCount: result.segments.count,
            textCharacterCount: result.text.count,
            outputTokenCount: result.timings.phases?.outputTokenCount,
            textSHA256: OpenCastSHA256.hash(Data(result.text.utf8)),
            segmentsSHA256: segmentsSHA256(for: result.segments)
        )
        return (metrics, result)
    }

    /// Bit-exact canonical segment digest for exact-output A/B gates.
    private static func segmentsSHA256(for segments: [OpenCastTranscriptSegment]) -> String {
        let canonical = segments
            .map { "\($0.start.bitPattern)|\($0.end.bitPattern)|\($0.text)" }
            .joined(separator: "\n")
        return OpenCastSHA256.hash(Data(canonical.utf8))
    }

    private static func modelSummary(
        model: OpenCastWhisperModel,
        version: String?,
        installsIfNeeded: Bool
    ) async throws -> OpenCastWhisperModelInstalledSummary {
        let resolvedVersion = version ?? model.defaultRemoteVersion
        let installStore = OpenCastWhisperModelInstallStore()
        do {
            return try installStore.installedSummary(
                modelIdentifier: model.rawValue,
                version: resolvedVersion
            )
        } catch let error as OpenCastTranscriptionError {
            guard case .modelNotInstalled = error, installsIfNeeded else {
                throw error
            }
        }

        _ = try await OpenCastWhisperModelInstaller().install(model: model, version: version)
        return try installStore.installedSummary(
            modelIdentifier: model.rawValue,
            version: resolvedVersion
        )
    }

    private static func selectedEpisode(
        from feed: FeedSnapshot,
        preferredEpisodeTitle: String?
    ) throws -> Episode {
        if let preferredEpisodeTitle,
           let episode = feed.episodes.first(where: { $0.title.localizedStandardContains(preferredEpisodeTitle) }) {
            return episode
        }

        guard let episode = feed.episodes.first(where: { $0.audioURL != nil }) else {
            throw OpenCastCoreError.missingAudioURL
        }
        return episode
    }

    private static func downloadAudioIfNeeded(_ audioURL: URL, episodeID: String) async throws -> URL {
        let destination = benchmarkDirectory()
            .appending(path: "Audio", directoryHint: .isDirectory)
            .appending(path: "\(BenchmarkHarnessSupport.safeStem(episodeID)).mp3")
        if FileManager.default.fileExists(atPath: destination.path),
           (try? fileByteCount(at: destination)) ?? 0 > 0 {
            return destination
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let (temporaryURL, response) = try await URLSession.shared.download(from: audioURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw OpenCastCoreError.invalidHTTPResponse
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private static func writeTranscriptDocument(
        result: OpenCastTranscriptionResult,
        episode: Episode,
        audioURL: URL,
        audioByteCount: Int64,
        audioSHA256: String,
        modelVersion: String,
        modelTreeSHA256: String
    ) async throws -> String {
        let fileStore = await EpisodeTranscriptFileStore()
        let fingerprint = fileStore.fingerprint(
            sourceFileSHA256: audioSHA256,
            modelIdentifier: result.modelIdentifier,
            modelVersion: modelVersion,
            modelTreeSHA256: modelTreeSHA256
        )
        let relativePath = fileStore.relativePath(
            episodeID: "benchmark-\(episode.id.rawValue)",
            fingerprint: fingerprint
        )
        let createdAt = Date.now
        let document = EpisodeTranscriptDocument(
            schemaVersion: EpisodeTranscriptDocument.currentSchemaVersion,
            episodeID: episode.id.rawValue,
            podcastID: episode.podcastID.rawValue,
            sourceAudioURL: audioURL.absoluteString,
            sourceFileByteCount: audioByteCount,
            sourceFileSHA256: audioSHA256,
            modelIdentifier: result.modelIdentifier,
            modelVersion: modelVersion,
            modelTreeSHA256: modelTreeSHA256,
            languageCode: result.languageCode,
            audioDuration: result.timings.audioDuration,
            checkpoints: [],
            segments: result.segments,
            text: result.text,
            timings: EpisodeTranscriptTimings(resultTimings: result.timings),
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try fileStore.write(document, relativePath: relativePath)
        return relativePath
    }

    @MainActor
    private static func batterySnapshot() -> (level: Double?, state: String) {
        let device = UIDevice.current
        let level = device.batteryLevel
        let state: String = switch device.batteryState {
        case .unplugged: "unplugged"
        case .charging: "charging"
        case .full: "full"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
        return (level >= 0 ? Double(level) : nil, state)
    }

    private static func reportURL(runLabel: String?, startedAt: Date) -> URL {
        let timestamp = startedAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        let stem = BenchmarkHarnessSupport.safeStem(([runLabel, timestamp].compactMap(\.self)).joined(separator: "-"))
        return benchmarkDirectory().appending(path: "benchmark-\(stem).json")
    }

    private static func benchmarkDirectory() -> URL {
        URL.applicationSupportDirectory
            .appending(path: "OpenCastTranscriptionBenchmark", directoryHint: .isDirectory)
    }

    private static func fileByteCount(at url: URL) throws -> Int64 {
        do {
            return try OpenCastFileByteCount.byteCount(at: url)
        } catch is OpenCastFileByteCount.NotARegularFile {
            return 0
        }
    }

}
