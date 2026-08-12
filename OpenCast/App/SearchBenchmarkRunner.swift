import Foundation
import OpenCastCore

/// Opt-in, Release-capable scaling harness for the production search engines.
///
/// Corpus construction and report writes occur outside the timed interval.
/// Each engine receives the same documents, query order, warmups, and repeats.
nonisolated struct SearchBenchmarkRunner: Sendable {
    static let requestArgument = "--opencast-run-search-benchmark"
    static let requestEnvironmentKey = "OPENCAST_RUN_SEARCH_BENCHMARK"
    static let runLabelArgument = "--opencast-search-benchmark-run-label"
    static let runLabelEnvironmentKey = "OPENCAST_SEARCH_BENCHMARK_RUN_LABEL"
    static let candidateOnlyArgument =
        "--opencast-search-benchmark-candidate-only"
    static let candidateOnlyEnvironmentKey =
        "OPENCAST_SEARCH_BENCHMARK_CANDIDATE_ONLY"
    static let documentCountArgument =
        "--opencast-search-benchmark-document-count"
    static let documentCountEnvironmentKey =
        "OPENCAST_SEARCH_BENCHMARK_DOCUMENT_COUNT"

    private static let documentCounts = [1_000, 5_000, 10_000, 25_000]
    private static let measuredQueryIDs = [
        "exact-orchard",
        "show-signal-loom",
        "notes-radical-pairs",
        "common-field",
        "no-result"
    ]
    private static let warmupCount = 1
    private static let measuredQueryRepetitions = 1

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
        let candidateOnly = arguments.contains(candidateOnlyArgument)
            || environment[candidateOnlyEnvironmentKey] == "1"
        let requestedDocumentCount = BenchmarkHarnessSupport.argumentValue(
            from: arguments,
            flag: documentCountArgument
        ).flatMap(Int.init)
            ?? environment[documentCountEnvironmentKey].flatMap(Int.init)
        let selectedDocumentCounts = requestedDocumentCount.flatMap { value in
            documentCounts.contains(value) ? [value] : nil
        } ?? documentCounts

        // Let launch-time cache and persistence tasks settle before timing.
        try? await Task.sleep(for: .seconds(3))
        await run(
            runLabel: runLabel,
            candidateOnly: candidateOnly,
            selectedDocumentCounts: selectedDocumentCounts
        )
    }

    @concurrent
    private static func run(
        runLabel: String,
        candidateOnly: Bool,
        selectedDocumentCounts: [Int]
    ) async {
        var report = SearchBenchmarkReport(
            status: .running,
            recordedAt: .now,
            completedAt: nil,
            errorMessage: nil,
            buildMode: BenchmarkHarnessSupport.buildMode,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
                ?? BenchmarkHarnessSupport.machineIdentifier(),
            simulatorUDID: ProcessInfo.processInfo.environment["SIMULATOR_UDID"],
            thermalState: BenchmarkHarnessSupport.thermalStateDescription,
            runKind: candidateOnly ? "candidate-only" : "paired",
            generatorVersion: SearchBenchmarkCorpusGenerator.version,
            generatorSeed: SearchBenchmarkCorpusGenerator.seed,
            warmupCountPerEngine: warmupCount,
            measuredQueryCountPerEngine: measuredQueryIDs.count,
            corpora: []
        )
        let reportURL = reportURL(runLabel: runLabel, recordedAt: report.recordedAt)

        do {
            guard BenchmarkHarnessSupport.buildMode == "Release" else {
                throw SearchBenchmarkRunnerError.releaseBuildRequired
            }
            try BenchmarkHarnessSupport.prepareReportDirectory(benchmarkDirectory())
            try BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)

            for documentCount in selectedDocumentCounts {
                let corpus = SearchBenchmarkCorpusGenerator.make(
                    documentCount: documentCount
                )
                var legacyDocuments = candidateOnly
                    ? nil
                    : corpus.documents.enumerated().map {
                        sourceIndex,
                        document in
                        EpisodeSearchDocument(
                            episodeID: document.episodeID,
                            sourceIndex: sourceIndex,
                            title: document.title,
                            podcastTitle: document.podcastTitle,
                            summaryHTML: document.summaryHTML,
                            showNotesHTML: document.showNotesHTML
                        )
                    }
                let queriesByID = Dictionary(
                    uniqueKeysWithValues: corpus.queries.map {
                        ($0.identifier, $0)
                    }
                )
                let measuredQueries = measuredQueryIDs.compactMap {
                    queriesByID[$0]
                }
                precondition(measuredQueries.count == measuredQueryIDs.count)
                let corpusRunIndex = report.corpora.endIndex
                var engineRuns: [SearchBenchmarkReport.EngineRun] = []
                if let legacyDocuments {
                    engineRuns.append(
                        await measureLegacy(
                            documents: legacyDocuments,
                            queries: measuredQueries
                        )
                    )
                }
                legacyDocuments = nil
                report.corpora.append(
                    SearchBenchmarkReport.CorpusRun(
                        documentCount: documentCount,
                        normalizedSourceByteCount: corpus.normalizedSourceByteCount,
                        corpusSHA256: corpus.sha256,
                        engines: engineRuns
                    )
                )
                try BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)
                let indexedRun = try await measureIndexed(
                    corpus: corpus,
                    queries: measuredQueries,
                    runLabel: runLabel
                )
                engineRuns.append(indexedRun)
                report.corpora[corpusRunIndex] =
                    SearchBenchmarkReport.CorpusRun(
                        documentCount: documentCount,
                        normalizedSourceByteCount:
                            corpus.normalizedSourceByteCount,
                        corpusSHA256: corpus.sha256,
                        engines: engineRuns
                    )
                try BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)
            }

            report.status = .completed
            report.completedAt = .now
            try BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)
        } catch {
            report.status = .failed
            report.completedAt = .now
            report.errorMessage = error.localizedDescription
            try? BenchmarkHarnessSupport.prepareReportDirectory(benchmarkDirectory())
            try? BenchmarkHarnessSupport.writeJSONReport(report, to: reportURL)
        }
    }

    @concurrent
    private static func measureLegacy(
        documents: [EpisodeSearchDocument],
        queries: [SearchBenchmarkCorpusGenerator.Query]
    ) async -> SearchBenchmarkReport.EngineRun {
        for index in 0..<warmupCount {
            let matches = await EpisodeSearch.matches(
                in: documents,
                query: queries[index % queries.count].text,
                mode: queries[index % queries.count].mode
            )
            _ = matches.prefix(10).map(\.episodeID)
        }

        let clock = ContinuousClock()
        let memorySampler = ProcessResidentMemorySampler()
        await memorySampler.start()
        var samples: [SearchBenchmarkReport.Sample] = []
        samples.reserveCapacity(queries.count * measuredQueryRepetitions)
        for _ in 0..<measuredQueryRepetitions {
            for query in queries {
                let start = clock.now
                let matches = await EpisodeSearch.matches(
                    in: documents,
                    query: query.text,
                    mode: query.mode
                )
                let topEpisodeIDs = matches.prefix(10).map(\.episodeID)
                let elapsed = start.duration(to: clock.now)
                samples.append(
                    SearchBenchmarkReport.Sample(
                        queryID: query.identifier,
                        durationMilliseconds: milliseconds(elapsed),
                        resultCount: matches.count,
                        topEpisodeIDs: topEpisodeIDs
                    )
                )
            }
        }
        let residentMemory = await memorySampler.stop()
        return SearchBenchmarkReport.engineRun(
            engineID: "legacy-six-bucket-v1",
            samples: samples,
            residentMemory: residentMemory
        )
    }

    @concurrent
    private static func measureIndexed(
        corpus: SearchBenchmarkCorpusGenerator.Corpus,
        queries: [SearchBenchmarkCorpusGenerator.Query],
        runLabel: String
    ) async throws -> SearchBenchmarkReport.EngineRun {
        let databaseURL = benchmarkDirectory().appending(
            path: BenchmarkHarnessSupport.safeStem(
                "candidate-\(runLabel)-\(corpus.documents.count)-\(UUID().uuidString)"
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
        try await store.checkpointForSearchBenchmark()
        let databaseBytesBeforePreparation = storageBytes(
            forDatabaseAt: databaseURL
        )

        let clock = ContinuousClock()
        let preparationStart = clock.now
        try await store.prepareEpisodeSearchIndex()
        let preparationMilliseconds = milliseconds(
            preparationStart.duration(to: clock.now)
        )
        try await store.checkpointForSearchBenchmark()
        let databaseBytesAfterPreparation = storageBytes(
            forDatabaseAt: databaseURL
        )
        let activePodcastIDs = Set(corpus.documents.map(\.podcastID))

        for index in 0..<warmupCount {
            let query = queries[index % queries.count]
            let hits = try await store.searchEpisodes(
                EpisodeSearchIndexRequest(
                    query: query.text,
                    mode: query.mode,
                    activePodcastIDs: activePodcastIDs,
                    limit: 10
                )
            )
            _ = hits.prefix(10).map(\.episodeID)
        }

        let memorySampler = ProcessResidentMemorySampler()
        await memorySampler.start()
        var samples: [SearchBenchmarkReport.Sample] = []
        samples.reserveCapacity(queries.count * measuredQueryRepetitions)
        for _ in 0..<measuredQueryRepetitions {
            for query in queries {
                try Task.checkCancellation()
                let start = clock.now
                let hits = try await store.searchEpisodes(
                    EpisodeSearchIndexRequest(
                        query: query.text,
                        mode: query.mode,
                        activePodcastIDs: activePodcastIDs,
                        limit: 10
                    )
                )
                let topEpisodeIDs = hits.prefix(10).map(\.episodeID)
                let elapsed = start.duration(to: clock.now)
                samples.append(
                    SearchBenchmarkReport.Sample(
                        queryID: query.identifier,
                        durationMilliseconds: milliseconds(elapsed),
                        resultCount: hits.count,
                        topEpisodeIDs: topEpisodeIDs
                    )
                )
            }
        }
        let residentMemory = await memorySampler.stop()
        return SearchBenchmarkReport.engineRun(
            engineID: "sqlite-fts5-fielded-transcript-compressed-v15",
            samples: samples,
            preparationMilliseconds: preparationMilliseconds,
            databaseBytesBeforePreparation: databaseBytesBeforePreparation,
            databaseBytesAfterPreparation: databaseBytesAfterPreparation,
            residentMemory: residentMemory
        )
    }

    static func feedSnapshots(
        from documents: [SearchBenchmarkCorpusGenerator.Document]
    ) -> [FeedSnapshot] {
        let documentsByPodcastID = Dictionary(
            grouping: documents,
            by: \.podcastID
        )
        return documentsByPodcastID.keys
            .sorted()
            .compactMap { podcastID in
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
                                string: "https://search-benchmark.invalid/audio/\(document.episodeID).mp3"
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
            total += (attributes?[.size] as? NSNumber)?.intValue ?? 0
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func reportURL(runLabel: String, recordedAt: Date) -> URL {
        let timestamp = recordedAt.formatted(
            .iso8601
                .year()
                .month()
                .day()
                .time(includingFractionalSeconds: false)
        )
        let stem = BenchmarkHarnessSupport.safeStem("\(runLabel)-\(timestamp)")
        return benchmarkDirectory().appending(path: "benchmark-\(stem).json")
    }

    private static func benchmarkDirectory() -> URL {
        URL.applicationSupportDirectory
            .appending(path: "OpenCastSearchBenchmark", directoryHint: .isDirectory)
    }

}

nonisolated private enum SearchBenchmarkRunnerError: LocalizedError {
    case releaseBuildRequired

    var errorDescription: String? {
        switch self {
        case .releaseBuildRequired:
            "Search benchmarks require a Release build."
        }
    }
}
