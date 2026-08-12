import Foundation
import OpenCastCore
import OpenCastTranscription
import SwiftData

/// Opt-in Release harness for search work outside the warm query-engine timer.
/// It covers the production debounce/mapping path, transactional metadata and
/// transcript updates, and transcript-index storage density.
nonisolated struct SearchPerformanceRunner: Sendable {
    static let requestArgument = "--opencast-run-search-performance"
    static let requestEnvironmentKey = "OPENCAST_RUN_SEARCH_PERFORMANCE"
    static let runLabelArgument = "--opencast-search-performance-run-label"
    static let runLabelEnvironmentKey =
        "OPENCAST_SEARCH_PERFORMANCE_RUN_LABEL"

    private static let documentCount = 25_000
    private static let warmupCount = 3
    private static let measuredSampleCount = 20
    private static let typingDebounce = Duration.milliseconds(120)
    private static let typingInterKeystroke = Duration.milliseconds(20)
    private static let transcriptUpdateSegmentCount = 60
    private static let transcriptUpdateAudioDuration: TimeInterval = 600
    private static let transcriptStorageSegmentCount = 360
    private static let transcriptStorageAudioDuration: TimeInterval = 3_600
    private static let engineID =
        "sqlite-fts5-fielded-transcript-compressed-v15"

    @concurrent
    static func runIfRequested() async {
        let processInfo = ProcessInfo.processInfo
        let arguments = processInfo.arguments
        let environment = processInfo.environment
        guard arguments.contains(requestArgument)
                || environment[requestEnvironmentKey] == "1"
        else {
            return
        }
        let runLabel = BenchmarkHarnessSupport.argumentValue(
            from: arguments,
            flag: runLabelArgument
        ) ?? environment[runLabelEnvironmentKey] ?? "unlabeled"

        try? await Task.sleep(for: .seconds(3))
        await run(runLabel: runLabel)
    }

    @concurrent
    private static func run(runLabel: String) async {
        let corpus = SearchBenchmarkCorpusGenerator.make(
            documentCount: documentCount
        )
        var report = SearchPerformanceReport(
            status: .running,
            recordedAt: .now,
            completedAt: nil,
            errorMessage: nil,
            buildMode: BenchmarkHarnessSupport.buildMode,
            operatingSystem:
                ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: ProcessInfo.processInfo.environment[
                "SIMULATOR_MODEL_IDENTIFIER"
            ] ?? BenchmarkHarnessSupport.machineIdentifier(),
            simulatorUDID: ProcessInfo.processInfo.environment[
                "SIMULATOR_UDID"
            ],
            thermalState: BenchmarkHarnessSupport.thermalStateDescription,
            engineID: engineID,
            generatorVersion: SearchBenchmarkCorpusGenerator.version,
            generatorSeed: SearchBenchmarkCorpusGenerator.seed,
            documentCount: documentCount,
            normalizedMetadataSourceByteCount:
                corpus.normalizedSourceByteCount,
            warmupCount: warmupCount,
            measuredSampleCount: measuredSampleCount,
            typingDebounceMilliseconds: 120,
            typingInterKeystrokeMilliseconds: 20,
            transcriptUpdateSegmentCount: transcriptUpdateSegmentCount,
            transcriptUpdateAudioDurationSeconds:
                transcriptUpdateAudioDuration,
            incrementalTyping: nil,
            metadataUpdate: nil,
            transcriptCanonicalAndIndexUpdate: nil,
            transcriptStorage: nil
        )
        let reportURL = reportURL(
            runLabel: runLabel,
            recordedAt: report.recordedAt
        )

        do {
            guard BenchmarkHarnessSupport.buildMode == "Release" else {
                throw SearchPerformanceRunnerError.releaseBuildRequired
            }
            try BenchmarkHarnessSupport.prepareReportDirectory(performanceDirectory())
            try BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)

            let databaseURL = performanceDirectory().appending(
                path: BenchmarkHarnessSupport.safeStem(
                    "performance-\(runLabel)-\(UUID().uuidString)"
                )
            ).appendingPathExtension("sqlite")
            let store = await MainActor.run {
                SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
            }
            for snapshot in feedSnapshots(from: corpus.documents) {
                try Task.checkCancellation()
                try await store.upsertCache(
                    from: snapshot,
                    refreshedAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            }
            try await store.prepareEpisodeSearchIndex()

            let activePodcastIDs = Set(corpus.documents.map(\.podcastID))
            let library = try await store.loadLibrary(
                activePodcastIDs: activePodcastIDs
            )
            report.incrementalTyping = try await measureIncrementalTyping(
                store: store,
                episodes: library.episodes,
                activePodcastIDs: activePodcastIDs,
                queries: corpus.queries
            )
            try BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)

            let metadataTarget = corpus.documents[14]
            report.metadataUpdate = try await measureMetadataUpdates(
                store: store,
                document: metadataTarget
            )
            try BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)

            let transcriptTarget = corpus.documents[15]
            report.transcriptCanonicalAndIndexUpdate = try await
                measureTranscriptLifecycleUpdates(
                    store: store,
                    document: transcriptTarget,
                    runLabel: runLabel
                )
            try BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)

            let storageTarget = corpus.documents[16]
            report.transcriptStorage = try await measureTranscriptStorage(
                document: storageTarget,
                runLabel: runLabel
            )

            report.status = .completed
            report.completedAt = .now
            try BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)
        } catch {
            report.status = .failed
            report.completedAt = .now
            report.errorMessage = error.localizedDescription
            try? BenchmarkHarnessSupport.prepareReportDirectory(performanceDirectory())
            try? BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)
        }
    }

    @MainActor
    private static func measureIncrementalTyping(
        store: SQLiteLocalLibraryCacheStore,
        episodes: [EpisodeListItemSnapshot],
        activePodcastIDs: Set<String>,
        queries: [SearchBenchmarkCorpusGenerator.Query]
    ) async throws -> SearchPerformanceReport.TimingDistribution {
        let selectedQueryIDs = [
            "exact-orchard",
            "show-signal-loom",
            "notes-radical-pairs",
            "common-field",
        ]
        let queriesByID = Dictionary(
            uniqueKeysWithValues: queries.map { ($0.identifier, $0) }
        )
        let selectedQueries = try selectedQueryIDs.map { queryID in
            guard let query = queriesByID[queryID] else {
                throw SearchPerformanceRunnerError.missingQuery(queryID)
            }
            return query
        }
        let session = EpisodeSearchSession()
        let clock = ContinuousClock()
        var samples: [SearchPerformanceReport.TimingSample] = []
        samples.reserveCapacity(measuredSampleCount)

        for sampleIndex in 0..<(warmupCount + measuredSampleCount) {
            let query = selectedQueries[sampleIndex % selectedQueries.count]
            var cancelledTasks: [Task<Void, Never>] = []
            var currentTask: Task<Void, Never>?
            let prefixes = incrementalPrefixes(for: query.text)
            for prefix in prefixes {
                currentTask?.cancel()
                if let currentTask {
                    cancelledTasks.append(currentTask)
                }
                currentTask = searchTask(
                    session: session,
                    store: store,
                    episodes: episodes,
                    query: prefix,
                    mode: query.mode,
                    activePodcastIDs: activePodcastIDs
                )
                try await Task.sleep(for: typingInterKeystroke)
            }
            currentTask?.cancel()
            if let currentTask {
                cancelledTasks.append(currentTask)
            }

            let start = clock.now
            let finalTask = searchTask(
                session: session,
                store: store,
                episodes: episodes,
                query: query.text,
                mode: query.mode,
                activePodcastIDs: activePodcastIDs
            )
            await finalTask.value
            let duration = start.duration(to: clock.now)
            for cancelledTask in cancelledTasks {
                await cancelledTask.value
            }

            guard !session.results.isEmpty else {
                throw SearchPerformanceRunnerError.emptyTypingResult(
                    query.identifier
                )
            }
            if sampleIndex >= warmupCount {
                samples.append(
                    SearchPerformanceReport.TimingSample(
                        sampleID:
                            "\(query.identifier)-\(sampleIndex - warmupCount)",
                        durationMilliseconds: milliseconds(duration),
                        resultCount: min(10, session.results.count),
                        cancellationCount: cancelledTasks.count
                    )
                )
            }
        }
        return SearchPerformanceReport.TimingDistribution(samples: samples)
    }

    @MainActor
    private static func searchTask(
        session: EpisodeSearchSession,
        store: SQLiteLocalLibraryCacheStore,
        episodes: [EpisodeListItemSnapshot],
        query: String,
        mode: EpisodeSearchMode,
        activePodcastIDs: Set<String>
    ) -> Task<Void, Never> {
        Task {
            await session.update(
                episodes: episodes,
                query: query,
                mode: mode,
                corpusRevision: 1,
                indexedSearchProvider: {
                    try? await store.searchEpisodes(
                        EpisodeSearchIndexRequest(
                            query: query,
                            mode: mode,
                            activePodcastIDs: activePodcastIDs,
                            limit: 10
                        )
                    )
                },
                debounceDuration: typingDebounce
            )
        }
    }

    @concurrent
    private static func measureMetadataUpdates(
        store: SQLiteLocalLibraryCacheStore,
        document: SearchBenchmarkCorpusGenerator.Document
    ) async throws -> SearchPerformanceReport.TimingDistribution {
        let clock = ContinuousClock()
        var samples: [SearchPerformanceReport.TimingSample] = []
        samples.reserveCapacity(measuredSampleCount)
        for sampleIndex in 0..<(warmupCount + measuredSampleCount) {
            let variant = sampleIndex.isMultiple(of: 2) ? "amber" : "cobalt"
            let snapshot = metadataUpdateSnapshot(
                document: document,
                variant: variant
            )
            let start = clock.now
            try await store.upsertCache(
                from: snapshot,
                refreshedAt: Date(
                    timeIntervalSince1970:
                        1_800_100_000 + TimeInterval(sampleIndex)
                )
            )
            let duration = start.duration(to: clock.now)
            if sampleIndex >= warmupCount {
                samples.append(
                    SearchPerformanceReport.TimingSample(
                        sampleID: "metadata-\(sampleIndex - warmupCount)",
                        durationMilliseconds: milliseconds(duration),
                        resultCount: nil,
                        cancellationCount: nil
                    )
                )
            }
        }
        let verificationHits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "amber mutation marker",
                mode: .fullText,
                activePodcastIDs: [document.podcastID],
                limit: 10
            )
        )
        guard verificationHits.first?.episodeID == document.episodeID else {
            throw SearchPerformanceRunnerError.metadataUpdateNotSearchable
        }
        return SearchPerformanceReport.TimingDistribution(samples: samples)
    }

    @MainActor
    private static func measureTranscriptLifecycleUpdates(
        store: SQLiteLocalLibraryCacheStore,
        document: SearchBenchmarkCorpusGenerator.Document,
        runLabel: String
    ) async throws -> SearchPerformanceReport.TimingDistribution {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let modelContext = ModelContext(container)
        let sidecarDirectory = performanceDirectory().appending(
            path: BenchmarkHarnessSupport.safeStem("transcript-updates-\(runLabel)-\(UUID().uuidString)"),
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: sidecarDirectory)
        }
        let transcriptionStore = EpisodeTranscriptionStore(
            fileStore: EpisodeTranscriptFileStore(
                baseDirectory: sidecarDirectory
            )
        )
        transcriptionStore.episodeSearchIndexStore = store
        await transcriptionStore.waitForEpisodeSearchIndexSync()

        let clock = ContinuousClock()
        var samples: [SearchPerformanceReport.TimingSample] = []
        samples.reserveCapacity(measuredSampleCount)
        for sampleIndex in 0..<(warmupCount + measuredSampleCount) {
            let variant = sampleIndex.isMultiple(of: 2) ? "amber" : "cobalt"
            let transcript = transcriptDocument(
                for: document,
                segmentCount: transcriptUpdateSegmentCount,
                audioDuration: transcriptUpdateAudioDuration,
                variant: variant,
                revision: sampleIndex
            )
            let start = clock.now
            try await transcriptionStore.importRemoteTranscript(
                transcript,
                modelContext: modelContext
            )
            await transcriptionStore.waitForEpisodeSearchIndexSync()
            let duration = start.duration(to: clock.now)
            if sampleIndex >= warmupCount {
                samples.append(
                    SearchPerformanceReport.TimingSample(
                        sampleID: "transcript-\(sampleIndex - warmupCount)",
                        durationMilliseconds: milliseconds(duration),
                        resultCount: nil,
                        cancellationCount: nil
                    )
                )
            }
        }

        let verificationHits = try await store.searchEpisodes(
            EpisodeSearchIndexRequest(
                query: "amber transcript marker",
                mode: .fullText,
                activePodcastIDs: [document.podcastID],
                limit: 10
            )
        )
        guard verificationHits.first?.episodeID == document.episodeID else {
            throw SearchPerformanceRunnerError.transcriptUpdateNotSearchable
        }
        return SearchPerformanceReport.TimingDistribution(samples: samples)
    }

    @concurrent
    private static func measureTranscriptStorage(
        document: SearchBenchmarkCorpusGenerator.Document,
        runLabel: String
    ) async throws -> SearchPerformanceReport.TranscriptStorage {
        let databaseURL = performanceDirectory().appending(
            path: BenchmarkHarnessSupport.safeStem(
                "transcript-storage-\(runLabel)-\(UUID().uuidString)"
            )
        ).appendingPathExtension("sqlite")
        let store = await MainActor.run {
            SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        }
        try await store.upsertCache(
            from: metadataUpdateSnapshot(
                document: document,
                variant: "storage"
            ),
            refreshedAt: Date(timeIntervalSince1970: 1_800_200_000)
        )
        try await store.prepareEpisodeSearchIndex()
        let segments = transcriptSegments(
            count: transcriptStorageSegmentCount,
            audioDuration: transcriptStorageAudioDuration,
            variant: "storage"
        )
        let normalizedSourceByteCount = segments.reduce(into: 0) {
            $0 += $1.text.utf8.count
        }
        try await store.checkpointForSearchBenchmark()
        let bytesBefore = storageBytes(forDatabaseAt: databaseURL)
        try await store.replaceEpisodeTranscriptSearchDocument(
            EpisodeSearchTranscriptDocument(
                episodeID: document.episodeID,
                podcastID: document.podcastID,
                version: "one-hour-storage-v1",
                segments: segments.map {
                    EpisodeSearchTranscriptSegment(
                        segmentID: String($0.id),
                        startSeconds: $0.start,
                        endSeconds: $0.end,
                        text: $0.text
                    )
                }
            )
        )
        try await store.checkpointForSearchBenchmark()
        let byteDelta = max(
            0,
            storageBytes(forDatabaseAt: databaseURL) - bytesBefore
        )
        let hours = transcriptStorageAudioDuration / 3_600
        return SearchPerformanceReport.TranscriptStorage(
            audioDurationSeconds: transcriptStorageAudioDuration,
            segmentCount: segments.count,
            normalizedSourceByteCount: normalizedSourceByteCount,
            derivedIndexByteDelta: byteDelta,
            derivedBytesPerTranscriptHour: Double(byteDelta) / hours,
            derivedToNormalizedSourceRatio:
                Double(byteDelta) / Double(normalizedSourceByteCount)
        )
    }

    private static func incrementalPrefixes(for query: String) -> [String] {
        let characterCount = query.count
        guard characterCount > 1 else {
            return []
        }
        let candidateCounts = [
            1,
            2,
            3,
            max(4, characterCount / 3),
            max(5, characterCount / 2),
            characterCount - 1,
        ]
        return Array(Set(candidateCounts))
            .filter { $0 > 0 && $0 < characterCount }
            .sorted()
            .map { String(query.prefix($0)) }
    }

    private static func metadataUpdateSnapshot(
        document: SearchBenchmarkCorpusGenerator.Document,
        variant: String
    ) -> FeedSnapshot {
        let feedURL = URL(
            string: "https://search-benchmark.invalid/\(document.podcastID).xml"
        )!
        return FeedSnapshot(
            podcast: Podcast(
                id: PodcastID(rawValue: document.podcastID),
                feedURL: feedURL,
                title: document.podcastTitle,
                author: nil,
                summary: nil,
                websiteURL: nil,
                artworkURL: nil
            ),
            episodes: [
                Episode(
                    id: EpisodeID(rawValue: document.episodeID),
                    podcastID: PodcastID(rawValue: document.podcastID),
                    podcastTitle: document.podcastTitle,
                    title: "\(document.title) \(variant) mutation marker",
                    summary: "\(document.summaryHTML) \(variant) update",
                    showNotesHTML:
                        "\(document.showNotesHTML) <p>\(variant) mutation marker</p>",
                    publishedAt: document.publishedAt,
                    duration: nil,
                    audioURL: URL(
                        string:
                            "https://search-benchmark.invalid/audio/\(document.episodeID).mp3"
                    ),
                    artworkURL: nil,
                    guid: document.episodeID
                )
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_800_100_000)
        )
    }

    private static func transcriptDocument(
        for document: SearchBenchmarkCorpusGenerator.Document,
        segmentCount: Int,
        audioDuration: TimeInterval,
        variant: String,
        revision: Int
    ) -> EpisodeTranscriptDocument {
        let segments = transcriptSegments(
            count: segmentCount,
            audioDuration: audioDuration,
            variant: variant
        )
        let sourceHash = String(format: "%064llx", UInt64(revision + 1))
        var transcript = EpisodeTranscriptDocument(
            schemaVersion: EpisodeTranscriptDocument.currentSchemaVersion,
            episodeID: document.episodeID,
            podcastID: document.podcastID,
            sourceAudioURL:
                "https://search-benchmark.invalid/audio/\(document.episodeID).mp3",
            sourceFileByteCount: Int64(
                segments.reduce(into: 0) { $0 += $1.text.utf8.count }
            ),
            sourceFileSHA256: sourceHash,
            modelIdentifier: "remote-search-benchmark",
            modelVersion: "1",
            modelTreeSHA256: "",
            languageCode: "en",
            audioDuration: audioDuration,
            checkpoints: [],
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            timings: EpisodeTranscriptTimings(),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(
                timeIntervalSince1970:
                    1_800_000_000 + TimeInterval(revision)
            )
        )
        transcript.providerModelIdentifier = "remote-search-benchmark"
        transcript.remoteServingContractVersion = "1"
        transcript.remotePipelineVersion = "1"
        transcript.normalizedTranscriptSHA256 = sourceHash
        return transcript
    }

    private static func transcriptSegments(
        count: Int,
        audioDuration: TimeInterval,
        variant: String
    ) -> [OpenCastTranscriptSegment] {
        let duration = audioDuration / Double(count)
        let topics = [
            "orchard navigation and magnetic field calibration",
            "coastal weather instruments and acoustic signal processing",
            "community archives preserve language memory and oral history",
            "wetland wildlife observation follows seasonal migration patterns",
            "radio repair uses ceramic receivers and conductive membranes",
            "garden pollinators respond to temperature and pressure changes",
        ]
        return (0..<count).map { index in
            let start = Double(index) * duration
            return OpenCastTranscriptSegment(
                id: index,
                start: start,
                end: start + duration,
                text: "\(variant) transcript marker \(topics[index % topics.count]) sequence \(index % 97)",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        }
    }

    private static func feedSnapshots(
        from documents: [SearchBenchmarkCorpusGenerator.Document]
    ) -> [FeedSnapshot] {
        let documentsByPodcastID = Dictionary(
            grouping: documents,
            by: \.podcastID
        )
        return documentsByPodcastID.keys.sorted().compactMap { podcastID in
            guard let podcastDocuments = documentsByPodcastID[podcastID],
                  let first = podcastDocuments.first
            else {
                return nil
            }
            let feedURL = URL(
                string: "https://search-benchmark.invalid/\(podcastID).xml"
            )!
            return FeedSnapshot(
                podcast: Podcast(
                    id: PodcastID(rawValue: podcastID),
                    feedURL: feedURL,
                    title: first.podcastTitle,
                    author: nil,
                    summary: nil,
                    websiteURL: nil,
                    artworkURL: nil
                ),
                episodes: podcastDocuments.map { document in
                    Episode(
                        id: EpisodeID(rawValue: document.episodeID),
                        podcastID: PodcastID(rawValue: document.podcastID),
                        podcastTitle: document.podcastTitle,
                        title: document.title,
                        summary: document.summaryHTML,
                        showNotesHTML: document.showNotesHTML,
                        publishedAt: document.publishedAt,
                        duration: nil,
                        audioURL: URL(
                            string:
                                "https://search-benchmark.invalid/audio/\(document.episodeID).mp3"
                        ),
                        artworkURL: nil,
                        guid: document.episodeID
                    )
                },
                fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }
    }

    private static func storageBytes(forDatabaseAt url: URL) -> Int {
        [
            url,
            URL(filePath: url.path + "-wal"),
            URL(filePath: url.path + "-shm"),
        ].reduce(into: 0) { total, fileURL in
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: fileURL.path
            )
            total += attributes?[.size] as? Int ?? 0
        }
    }

    private static func performanceDirectory() -> URL {
        URL.applicationSupportDirectory.appending(
            path: "OpenCastSearchPerformance",
            directoryHint: .isDirectory
        )
    }

    private static func reportURL(runLabel: String, recordedAt: Date) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withDashSeparatorInDate,
            .withColonSeparatorInTime,
        ]
        let timestamp = formatter.string(from: recordedAt)
            .replacing(":", with: "-")
        return performanceDirectory().appending(
            path: "performance-\(BenchmarkHarnessSupport.safeStem(runLabel))-\(timestamp).json"
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

}

nonisolated enum SearchPerformanceRunnerError: LocalizedError, Sendable {
    case releaseBuildRequired
    case missingQuery(String)
    case emptyTypingResult(String)
    case metadataUpdateNotSearchable
    case transcriptUpdateNotSearchable

    var errorDescription: String? {
        switch self {
        case .releaseBuildRequired:
            "Search performance benchmarks require a Release build."
        case .missingQuery(let queryID):
            "Search performance query is missing: \(queryID)."
        case .emptyTypingResult(let queryID):
            "Incremental typing returned no result for \(queryID)."
        case .metadataUpdateNotSearchable:
            "The measured metadata update did not reach the search index."
        case .transcriptUpdateNotSearchable:
            "The measured transcript update did not reach the search index."
        }
    }
}
