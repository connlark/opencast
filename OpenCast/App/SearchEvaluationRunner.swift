import CryptoKit
import Foundation
import OpenCastCore

/// Opt-in runner for the frozen, sanitized local-search relevance fixtures.
///
/// Inputs are copied into the simulator's Documents/SearchEvaluationInputs
/// directory by the evaluation lane. Rankings are written only after every
/// query completes, so the host never mistakes a partial artifact for a run.
nonisolated struct SearchEvaluationRunner: Sendable {
    static let requestArgument = "--opencast-run-search-evaluation"
    static let requestEnvironmentKey = "OPENCAST_RUN_SEARCH_EVALUATION"
    static let splitArgument = "--opencast-search-evaluation-split"
    static let splitEnvironmentKey = "OPENCAST_SEARCH_EVALUATION_SPLIT"
    static let revisionEnvironmentKey = "OPENCAST_SEARCH_EVALUATION_REVISION"

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
        let split = BenchmarkHarnessSupport.argumentValue(
            from: arguments,
            flag: splitArgument
        ) ?? environment[splitEnvironmentKey] ?? "development"
        let sourceRevision = environment[revisionEnvironmentKey] ?? "working-tree"
        await run(split: split, sourceRevision: sourceRevision)
    }

    @concurrent
    private static func run(
        split: String,
        sourceRevision: String
    ) async {
        let statusURL = outputDirectory().appending(path: "status-\(split).json")
        do {
            guard split == "development" || split == "held_out" else {
                throw SearchEvaluationError.invalidSplit(split)
            }
            try BenchmarkHarnessSupport.prepareReportDirectory(outputDirectory())
            try writeStatus(
                Status(status: "running", errorMessage: nil),
                to: statusURL
            )

            let corpusURL = inputDirectory().appending(path: "corpus-v1.json")
            let queryFilename = split == "development"
                ? "queries-development-v1.json"
                : "queries-held-out-v1.json"
            let queryURL = inputDirectory().appending(path: queryFilename)
            let corpusData = try Data(contentsOf: corpusURL)
            let queryData = try Data(contentsOf: queryURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let corpus = try decoder.decode(Corpus.self, from: corpusData)
            let querySet = try decoder.decode(QuerySet.self, from: queryData)
            guard corpus.datasetVersion == querySet.datasetVersion,
                  querySet.split == split
            else {
                throw SearchEvaluationError.fixtureMismatch
            }

            let legacy = await legacyRankings(
                corpus: corpus,
                querySet: querySet,
                corpusSHA256: sha256(corpusData),
                querySetSHA256: sha256(queryData),
                sourceRevision: sourceRevision
            )
            let indexed = try await indexedRankings(
                corpus: corpus,
                querySet: querySet,
                corpusSHA256: sha256(corpusData),
                querySetSHA256: sha256(queryData),
                sourceRevision: sourceRevision
            )

            try write(
                legacy,
                to: outputDirectory().appending(
                    path: "rankings-\(split)-legacy.json"
                )
            )
            try write(
                indexed,
                to: outputDirectory().appending(
                    path: "rankings-\(split)-fts.json"
                )
            )
            try writeStatus(
                Status(status: "completed", errorMessage: nil),
                to: statusURL
            )
        } catch {
            try? BenchmarkHarnessSupport.prepareReportDirectory(outputDirectory())
            try? writeStatus(
                Status(
                    status: "failed",
                    errorMessage: error.localizedDescription
                ),
                to: statusURL
            )
        }
    }

    @concurrent
    private static func legacyRankings(
        corpus: Corpus,
        querySet: QuerySet,
        corpusSHA256: String,
        querySetSHA256: String,
        sourceRevision: String
    ) async -> Rankings {
        let documents = corpus.documents.enumerated().map {
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
        var results: [QueryResult] = []
        results.reserveCapacity(querySet.queries.count)
        for query in querySet.queries {
            let matches = await EpisodeSearch.matches(
                in: documents,
                query: query.text,
                mode: .fullText
            )
            results.append(
                QueryResult(
                    queryID: query.queryID,
                    matches: matches.prefix(50).map {
                        RankingMatch(
                            episodeID: $0.episodeID,
                            score: nil,
                            passage: nil
                        )
                    }
                )
            )
        }
        return Rankings(
            systemID: "legacy-six-bucket-v1",
            datasetVersion: corpus.datasetVersion,
            split: querySet.split,
            corpusSHA256: corpusSHA256,
            querySetSHA256: querySetSHA256,
            sourceRevision: sourceRevision,
            configuration: .legacy,
            results: results
        )
    }

    @concurrent
    private static func indexedRankings(
        corpus: Corpus,
        querySet: QuerySet,
        corpusSHA256: String,
        querySetSHA256: String,
        sourceRevision: String
    ) async throws -> Rankings {
        let store = await MainActor.run {
            SQLiteLocalLibraryCacheStore.inMemory()
        }
        let snapshots = feedSnapshots(from: corpus.documents)
        for snapshot in snapshots {
            try await store.upsertCache(from: snapshot, refreshedAt: .now)
        }
        try await store.prepareEpisodeSearchIndex()
        for document in corpus.documents where !document.transcriptSegments.isEmpty {
            try await store.replaceEpisodeTranscriptSearchDocument(
                EpisodeSearchTranscriptDocument(
                    episodeID: document.episodeID,
                    podcastID: document.podcastID,
                    version: document.transcriptVersion ?? "fixture-unversioned",
                    segments: document.transcriptSegments.map { segment in
                        EpisodeSearchTranscriptSegment(
                            segmentID: segment.segmentID,
                            startSeconds: segment.startSeconds,
                            endSeconds: segment.endSeconds,
                            text: segment.text
                        )
                    }
                )
            )
        }
        let activePodcastIDs = Set(corpus.documents.map(\.podcastID))

        var results: [QueryResult] = []
        results.reserveCapacity(querySet.queries.count)
        for query in querySet.queries {
            try Task.checkCancellation()
            let hits = try await store.searchEpisodes(
                EpisodeSearchIndexRequest(
                    query: query.text,
                    mode: .fullText,
                    activePodcastIDs: activePodcastIDs
                )
            )
            results.append(
                QueryResult(
                    queryID: query.queryID,
                    matches: hits.map {
                        RankingMatch(
                            episodeID: $0.episodeID,
                            score: $0.scoreTrace.finalScore,
                            passage: $0.transcriptPassage.map { passage in
                                Passage(
                                    segmentID: passage.segmentID,
                                    startSeconds: passage.startSeconds,
                                    endSeconds: passage.endSeconds
                                )
                            }
                        )
                    }
                )
            )
        }
        return Rankings(
            systemID: "sqlite-fts5-fielded-transcript-compressed-v15",
            datasetVersion: corpus.datasetVersion,
            split: querySet.split,
            corpusSHA256: corpusSHA256,
            querySetSHA256: querySetSHA256,
            sourceRevision: sourceRevision,
            configuration: .fts,
            results: results
        )
    }

    private static func feedSnapshots(
        from documents: [CorpusDocument]
    ) -> [FeedSnapshot] {
        let documentsByPodcastID = Dictionary(grouping: documents, by: \.podcastID)
        return documentsByPodcastID.keys.sorted().compactMap { podcastID in
            guard let podcastDocuments = documentsByPodcastID[podcastID],
                  let first = podcastDocuments.first
            else {
                return nil
            }
            let feedURL = URL(
                string: "https://search-evaluation.invalid/\(podcastID).xml"
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
                            string: "https://search-evaluation.invalid/audio/\(document.episodeID).mp3"
                        ),
                        artworkURL: nil,
                        guid: document.episodeID
                    )
                },
                fetchedAt: .now
            )
        }
    }

    private static func inputDirectory() -> URL {
        URL.documentsDirectory
            .appending(path: "SearchEvaluationInputs", directoryHint: .isDirectory)
    }

    private static func outputDirectory() -> URL {
        URL.applicationSupportDirectory
            .appending(path: "OpenCastSearchEvaluation", directoryHint: .isDirectory)
    }

    private static func write(_ rankings: Rankings, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rankings).write(to: url, options: [.atomic])
    }

    private static func writeStatus(_ status: Status, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(status).write(to: url, options: [.atomic])
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private struct Status: Codable {
        let status: String
        let errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case status
            case errorMessage = "error_message"
        }
    }

    private struct Corpus: Decodable, Sendable {
        let datasetVersion: String
        let documents: [CorpusDocument]

        enum CodingKeys: String, CodingKey {
            case datasetVersion = "dataset_version"
            case documents
        }
    }

    private struct CorpusDocument: Decodable, Sendable {
        let episodeID: String
        let podcastID: String
        let podcastTitle: String
        let title: String
        let summaryHTML: String
        let showNotesHTML: String
        let publishedAt: Date?
        let transcriptSegments: [CorpusTranscriptSegment]
        let transcriptVersion: String?

        enum CodingKeys: String, CodingKey {
            case episodeID = "episode_id"
            case podcastID = "podcast_id"
            case podcastTitle = "podcast_title"
            case title
            case summaryHTML = "summary_html"
            case showNotesHTML = "show_notes_html"
            case publishedAt = "published_at"
            case transcriptSegments = "transcript_segments"
            case transcriptVersion = "transcript_version"
        }
    }

    private struct CorpusTranscriptSegment: Decodable, Sendable {
        let segmentID: String
        let startSeconds: TimeInterval
        let endSeconds: TimeInterval
        let text: String

        enum CodingKeys: String, CodingKey {
            case segmentID = "segment_id"
            case startSeconds = "start_seconds"
            case endSeconds = "end_seconds"
            case text
        }
    }

    private struct QuerySet: Decodable, Sendable {
        let datasetVersion: String
        let split: String
        let queries: [EvaluationQuery]

        enum CodingKeys: String, CodingKey {
            case datasetVersion = "dataset_version"
            case split
            case queries
        }
    }

    private struct EvaluationQuery: Decodable, Sendable {
        let queryID: String
        let text: String

        enum CodingKeys: String, CodingKey {
            case queryID = "query_id"
            case text
        }
    }

    private struct Rankings: Encodable {
        let systemID: String
        let datasetVersion: String
        let split: String
        let corpusSHA256: String
        let querySetSHA256: String
        let sourceRevision: String
        let configuration: Configuration
        let results: [QueryResult]

        enum CodingKeys: String, CodingKey {
            case systemID = "system_id"
            case datasetVersion = "dataset_version"
            case split
            case corpusSHA256 = "corpus_sha256"
            case querySetSHA256 = "query_set_sha256"
            case sourceRevision = "source_revision"
            case configuration
            case results
        }
    }

    private struct Configuration: Encodable {
        let engine: String
        let tokenizer: String?
        let fieldWeights: [Double]?
        let channels: [String]?
        let resultLimit: Int
        let recencyMaximum: Double?
        let relaxedMinimumShouldMatch: String?
        let typoMaximumDistance: Int?
        let typoMinimumTermLength: Int?
        let typoMaximumCorrections: Int?
        let typoCandidateLimit: Int?
        let morphologicalPrefixLength: Int?
        let inflectionPolicy: String?
        let transcriptUnit: String?
        let transcriptCandidateLimit: Int?
        let transcriptAggregation: String?
        let transcriptFusion: String?

        static let legacy = Configuration(
            engine: "legacy-six-bucket-v1",
            tokenizer: nil,
            fieldWeights: nil,
            channels: nil,
            resultLimit: 50,
            recencyMaximum: nil,
            relaxedMinimumShouldMatch: nil,
            typoMaximumDistance: nil,
            typoMinimumTermLength: nil,
            typoMaximumCorrections: nil,
            typoCandidateLimit: nil,
            morphologicalPrefixLength: nil,
            inflectionPolicy: nil,
            transcriptUnit: nil,
            transcriptCandidateLimit: nil,
            transcriptAggregation: nil,
            transcriptFusion: nil
        )
        static let fts = Configuration(
            engine: "sqlite-fts5-fielded-transcript-compressed-v15",
            tokenizer: "unicode61 remove_diacritics 2; on-demand conditional prefix; contentless column-detail; zlib derived evidence and spelling manifests",
            fieldWeights: [12, 8, 3, 1.5],
            channels: [
                "exact",
                "final-prefix",
                "relaxed-all-but-one-when-under-20",
                "corrected-oov",
                "corrected-final-prefix",
                "corpus-unique-morphological-root",
                "transcript-segment",
                "fts-rank-streaming-then-deterministic-swift-scoring",
                "index-write-cleaned-top-ten-body-evidence",
                "bounded-unsegmented-cjk-visible-substring",
            ],
            resultLimit: 50,
            recencyMaximum: 0.2,
            relaxedMinimumShouldMatch: "two-terms:1; three-or-more:n-1",
            typoMaximumDistance: 1,
            typoMinimumTermLength: EpisodeSearchSpelling.minimumTermLength,
            typoMaximumCorrections: EpisodeSearchSpelling.maximumCorrectedTermCount,
            typoCandidateLimit: EpisodeSearchSpelling.candidateLimit,
            morphologicalPrefixLength:
                EpisodeSearchSpelling.minimumMorphologicalPrefixLength,
            inflectionPolicy: "direct one-edit first; trailing-s fallback",
            transcriptUnit: "timed source segment",
            transcriptCandidateLimit: 200,
            transcriptAggregation: "max + min(4, 0.2*second) + min(2, 0.1*third)",
            transcriptFusion: "metadata + min(8, 0.35*transcript); transcript standalone"
        )

        enum CodingKeys: String, CodingKey {
            case engine
            case tokenizer
            case fieldWeights = "field_weights"
            case channels
            case resultLimit = "result_limit"
            case recencyMaximum = "recency_maximum"
            case relaxedMinimumShouldMatch = "relaxed_minimum_should_match"
            case typoMaximumDistance = "typo_maximum_distance"
            case typoMinimumTermLength = "typo_minimum_term_length"
            case typoMaximumCorrections = "typo_maximum_corrections"
            case typoCandidateLimit = "typo_candidate_limit"
            case morphologicalPrefixLength = "morphological_prefix_length"
            case inflectionPolicy = "inflection_policy"
            case transcriptUnit = "transcript_unit"
            case transcriptCandidateLimit = "transcript_candidate_limit"
            case transcriptAggregation = "transcript_aggregation"
            case transcriptFusion = "transcript_fusion"
        }
    }

    private struct QueryResult: Encodable {
        let queryID: String
        let matches: [RankingMatch]

        enum CodingKeys: String, CodingKey {
            case queryID = "query_id"
            case matches
        }
    }

    private struct RankingMatch: Encodable {
        let episodeID: String
        let score: Double?
        let passage: Passage?

        enum CodingKeys: String, CodingKey {
            case episodeID = "episode_id"
            case score
            case passage
        }
    }

    private struct Passage: Encodable {
        let segmentID: String
        let startSeconds: TimeInterval
        let endSeconds: TimeInterval

        enum CodingKeys: String, CodingKey {
            case segmentID = "segment_id"
            case startSeconds = "start_seconds"
            case endSeconds = "end_seconds"
        }
    }
}

nonisolated private enum SearchEvaluationError: LocalizedError {
    case invalidSplit(String)
    case fixtureMismatch

    var errorDescription: String? {
        switch self {
        case .invalidSplit(let split):
            "Invalid search-evaluation split: \(split)"
        case .fixtureMismatch:
            "Search-evaluation fixture versions or split do not match."
        }
    }
}
