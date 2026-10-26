import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import OpenCastPlayback
import OpenCastTranscription
import Security
import SwiftData
import SwiftUI
import Testing
@testable import OpenCast

/// No textual, reflected or exported form of the key stores holds any
/// eight-character run of a saved fixture key.
@MainActor
@Suite("Provider key leaks")
struct AnalysisProviderKeyLeakTests {
    private static let episodeID = "leak-episode"
    private static let feedURL = "https://example.com/leak-feed.xml"
    private static let audioURL = "https://example.com/leak-episode.mp3"

    @Test("Stores, storages and presences describe, reflect and dump without a key")
    func storesAndStoragesHoldNoKey() async throws {
        let service = AnalysisKeychainTestService()
        defer { service.deleteAll() }
        let keychain = service.storage()
        try keychain.save(AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText), provider: .google, syncs: true)
        try keychain.save(AnalysisKeyFixtures.key(AnalysisKeyFixtures.openAIText), provider: .openai, syncs: false)
        let inMemory = InMemoryAnalysisProviderKeyStorage(seeded: [
            .google: (AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText), syncs: true),
            .openai: (AnalysisKeyFixtures.key(AnalysisKeyFixtures.openAIText), syncs: false),
        ])
        let keychainStore = AnalysisProviderKeyStore(storage: keychain)
        let inMemoryStore = AnalysisProviderKeyStore(storage: inMemory)
        await keychainStore.refreshPresences()
        await inMemoryStore.refreshPresences()
        #expect(keychainStore.hasSavedKey && inMemoryStore.hasSavedKey)
        let readGoogleKey = try keychain.key(for: .google)
        let readOpenAIKey = try inMemoryStore.key(for: .openai)

        let subjects: [(String, Any)] = [
            ("Keychain storage", keychain),
            ("in-memory storage", inMemory),
            ("Keychain-backed store", keychainStore),
            ("in-memory store", inMemoryStore),
            ("Keychain-backed presences", keychainStore.presences),
            ("in-memory presences", inMemoryStore.presences),
            ("read Google key", readGoogleKey as Any),
            ("read OpenAI key", readOpenAIKey as Any),
        ]
        for (label, subject) in subjects {
            expectNoKey(in: subject, label)
        }
    }

    @Test("The key sheet's typed draft, and the state holding it, reflect without the key")
    func typedDraftHoldsNoKey() {
        let draft = AnalysisKeyDraft(text: AnalysisKeyFixtures.googleText)
        #expect(draft.text == AnalysisKeyFixtures.googleText)
        expectNoKey(in: draft, "typed draft")
        expectNoKey(in: SwiftUI.State(initialValue: draft), "the sheet's draft state")
    }

    @Test("Every store error, and every error an injected Keychain fault throws, reads without a key")
    func errorsHoldNoKey() throws {
        let service = AnalysisKeychainTestService()
        defer { service.deleteAll() }
        let faults = AnalysisKeychainFaultScript()
        let storage = service.storage(fault: faults.fault)
        try storage.save(AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText), provider: .google, syncs: true)

        var errors: [AnalysisProviderKeyStoreError] = [.notSaved, .unreadable]
        for operation in [AnalysisProviderKeyStoreError.Operation.read, .add, .update, .delete] {
            errors.append(.keychain(operation: operation, status: errSecInteractionNotAllowed))
        }

        let key = AnalysisKeyFixtures.key(AnalysisKeyFixtures.openAIText)
        let attempts: [(AnalysisProviderKeyStoreError.Operation, OSStatus, () throws -> Void)] = [
            (.read, errSecNotAvailable, { _ = try storage.key(for: .google) }),
            (.read, errSecNotAvailable, { _ = try storage.presence(for: .google) }),
            (.add, errSecInteractionNotAllowed, { try storage.save(key, provider: .openai, syncs: false) }),
            (.delete, errSecInteractionNotAllowed, { try storage.setSyncs(false, provider: .google) }),
            (.delete, errSecInteractionNotAllowed, { try storage.remove(provider: .google, includingSyncedCopy: true) }),
        ]
        for (operation, status, attempt) in attempts {
            faults.fail(operation, with: status)
            do {
                try attempt()
                Issue.record("An injected \(operation.rawValue) fault did not fail the call")
            } catch let error as AnalysisProviderKeyStoreError {
                errors.append(error)
            } catch {
                Issue.record("An injected \(operation.rawValue) fault threw another error type")
            }
            faults.clear()
        }
        service.add(account: "openai", text: "   ", synchronizable: false)
        do throws(AnalysisProviderKeyStoreError) {
            _ = try storage.key(for: .openai)
        } catch {
            errors.append(error)
        }

        #expect(errors.count == 12)
        for error in errors {
            expectNoKey(in: error, "error \(error)")
            #expect(!AnalysisKeyFixtures.containsFragment(error.localizedDescription))
        }
    }

    @Test("The episode diagnostics report holds no key, with a download, transcript, ad analysis, a Chapters failure and run records")
    func diagnosticsReportHoldsNoKey() async throws {
        let service = AnalysisKeychainTestService()
        defer { service.deleteAll() }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AnalysisProviderKeyLeakTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let downloadFileStore = EpisodeDownloadFileStore(baseDirectory: directory)
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: directory)
        let adAnalysisFileStore = EpisodeAdAnalysisFileStore(baseDirectory: directory)
        let storage = service.storage()
        try storage.save(AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText), provider: .google, syncs: true)
        try storage.save(AnalysisKeyFixtures.key(AnalysisKeyFixtures.openAIText), provider: .openai, syncs: false)
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: DownloadStore(downloader: RecordingHangingEpisodeAudioDownloader(), fileStore: downloadFileStore),
            transcriptions: EpisodeTranscriptionStore(fileStore: transcriptFileStore),
            adAnalyses: EpisodeAdAnalysisStore(fileStore: adAnalysisFileStore),
            analysisPolicy: .fixed(.baked),
            analysisKeys: AnalysisProviderKeyStore(storage: storage),
            analysisKeyTester: FixedAnalysisKeyTester(),
            analysisRuns: AnalysisRunRecordStore(directory: directory.appending(path: "AnalysisRuns")),
            allowsAutomaticFeedRefresh: false
        )
        try seedDownload(fileStore: downloadFileStore, context: context)
        try seedRuns(in: appModel.analysisRuns)
        try seedChaptersFailure(
            message: ChaptersSummaryFailureMapping.failure(
                AnalysisFailure(feature: .chaptersSummary, code: .providerRejected, status: 502),
                listenerFailure: .invalidKey
            ).message,
            context: context
        )
        try seedTranscriptAndAnalysis(
            transcriptFileStore: transcriptFileStore,
            adAnalysisFileStore: adAnalysisFileStore,
            context: context
        )
        await appModel.downloads.load(modelContext: context)
        appModel.loadLocalTranscriptionState(modelContext: context)
        appModel.analysisProviderSelection.load(modelContext: context)
        appModel.analysisUsage.load(modelContext: context)
        await appModel.analysisKeys.refreshPresences()
        #expect(appModel.analysisKeys.hasSavedKey)
        #expect(appModel.analysisProviderSelection.setProvider(.openai, for: .chaptersSummary, modelContext: context))
        #expect(appModel.analysisUsage.record(
            provider: .google,
            feature: .adDetection,
            inputTokens: 1_200,
            outputTokens: 300,
            at: .now,
            modelContext: context
        ))

        let idle = EpisodeDiagnosticsPlaybackSnapshot(
            loadedEpisodeID: nil,
            stateDescription: "idle",
            rate: 1,
            position: 0,
            duration: nil,
            assetURL: nil,
            sourceKindDescription: nil,
            itemDuration: nil,
            installedAutoSkipZones: [],
            displayOnlyZones: [],
            lastAutoSkipZoneID: nil,
            lastAutoSkipSequence: nil,
            isAutoSkipEnabled: true
        )
        let model = EpisodeDiagnosticsModel(
            episodeID: Self.episodeID,
            dependencies: EpisodeDiagnosticsDependencies(
                fileInspector: CannedFileInspector(),
                networkProber: CannedNetworkProber(),
                playbackSnapshot: { _ in idle },
                ensureCompletedDownload: { _, _, _ in throw CancellationError() },
                prepareShareFile: { source, _, _ in EpisodeDiagnosticsShareFile(url: source, temporaryDirectoryURL: nil) },
                cleanUpShareFile: { _ in }
            )
        )
        await model.load(appModel: appModel)
        let report = model.reportText()

        #expect(report.contains("== Zone Matrix =="))
        #expect(report.contains(Self.audioURL))
        #expect(report.contains("Span #1"))
        #expect(report.contains("== Analysis Runs =="))
        #expect(report.contains("Chapters & Summary · Listener Failure: invalid_key"))
        #expect(report.contains("Ad Detection · Route: trial"))
        #expect(report.contains("Error: Chapters & Summary failed (invalid_key)."))
        #expect(!AnalysisKeyFixtures.containsFragment(report))
        expectNoKey(in: appModel.analysisKeys, "app model's key store")
        expectNoKey(in: appModel.analysisProviderSelection, "app model's provider selection")
        expectNoKey(in: appModel.analysisUsage, "app model's usage")
    }

    @Test("The analysis runs export and the episode's Analysis Runs block read run records only")
    func analysisRunsExportHoldsNoKeyOrText() async throws {
        let directory = URL.temporaryDirectory
            .appending(path: "analysis-key-leak-runs-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runs = AnalysisRunRecordStore(directory: directory.appending(path: "AnalysisRuns"))
        try seedRuns(in: runs)
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        // A record a provider body could once have written: the export and
        // the block must never read it.
        try seedChaptersFailure(
            message: "Chapters & Summary failed: \(AnalysisKeyFixtures.googleText) \(Self.transcriptWord)",
            context: context
        )

        let records = runs.records(limit: AnalysisRunsExport.maximumRuns)
        #expect(records.count == 2)
        let export = String(
            decoding: try AnalysisRunsExport.data(entries: records.map(AnalysisRunsExportEntry.init), generatedAt: .now),
            as: UTF8.self
        )
        let block = EpisodeDiagnosticsModel.analysisRunsSection(records: records, episodeID: Self.episodeID)
        let blockText = block.rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        for text in [export, blockText] {
            #expect(!AnalysisKeyFixtures.containsFragment(text))
            #expect(!text.contains(Self.transcriptWord))
            #expect(!text.contains(Self.feedURL))
            #expect(!text.contains(Self.episodeID))
            #expect(!text.contains("leak-fingerprint"))
        }
        #expect(export.contains("invalid_key"))
        #expect(blockText.contains("invalid_key"))
    }

    @Test("The performance export holds no key")
    func performanceExportHoldsNoKey() async throws {
        let directory = URL.temporaryDirectory
            .appending(path: "analysis-key-leak-performance-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PerformanceReportStore(directory: directory)
        let state = try #require(PerformanceState(domain: .playback, label: "playing"))
        try await store.save(PerformanceReport(
            id: UUID(),
            receivedAt: .now,
            appVersion: "1.0 (1)",
            toolchainVersion: "27A266a",
            kind: .metrics,
            timeRange: DateInterval(start: .now, duration: 1),
            states: [state]
        ))
        let export = directory.deletingLastPathComponent().appending(path: "\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: export) }

        _ = try await store.export(to: export)

        let exported = try Data(contentsOf: export)
        let text = String(decoding: exported, as: UTF8.self)
        #expect(text.contains("playing"))
        #expect(!AnalysisKeyFixtures.containsFragment(text))
    }

    // MARK: - Helpers

    private func expectNoKey(in subject: Any, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        var dumped = ""
        dump(subject, to: &dumped)
        for (form, text) in [
            ("description", String(describing: subject)),
            ("reflection", String(reflecting: subject)),
            ("dump", dumped),
        ] {
            #expect(
                !AnalysisKeyFixtures.containsFragment(text),
                "The \(form) of the \(label) holds part of a fixture key",
                sourceLocation: sourceLocation
            )
        }
    }

    private static let transcriptWord = "Zanzibarian"

    /// A failed direct Chapters run and a finished trial ad run on the leak
    /// episode, each with the leak feed address and a fingerprint on the
    /// record; the policy revision of the Chapters run carries a key, so the
    /// export's grammar must refuse it.
    private func seedRuns(in runs: AnalysisRunRecordStore) throws {
        let snapshot = AnalysisPolicySnapshot.baked
        let chapters = try #require(snapshot.chaptersSummary(provider: .openai))
        var settings = chapters.settings
        settings.revision = "rev \(AnalysisKeyFixtures.openAIText)"
        let chaptersPolicy = AnalysisRoutePolicy.chaptersSummary(AnalysisPolicy(
            bundleVersion: chapters.bundleVersion,
            source: chapters.source,
            settings: settings,
            model: chapters.model
        ))
        let ads = AnalysisRoutePolicy.adDetection(try #require(snapshot.adDetection(provider: .google)))
        let chaptersRun = AnalysisRunRecord(
            feature: .chaptersSummary,
            episodeID: Self.episodeID,
            podcastID: Self.feedURL,
            transcriptFingerprint: "leak-fingerprint",
            resolution: AnalysisRouteResolution(
                feature: .chaptersSummary,
                route: .direct(provider: .openai),
                policy: chaptersPolicy,
                key: AnalysisKeyFixtures.key(AnalysisKeyFixtures.openAIText),
                resumingRunID: nil,
                trialExchange: nil
            ),
            policy: chaptersPolicy
        )
        try runs.begin(chaptersRun)
        runs.finish(
            runID: chaptersRun.id,
            outcome: .failed(AnalysisFailure(feature: .chaptersSummary, code: .providerRejected, status: 502)),
            listenerFailure: .invalidKey,
            background: true
        )
        let adsRun = AnalysisRunRecord(
            feature: .adDetection,
            episodeID: Self.episodeID,
            podcastID: Self.feedURL,
            transcriptFingerprint: "leak-fingerprint",
            resolution: AnalysisRouteResolution(
                feature: .adDetection,
                route: .trial,
                policy: ads,
                key: nil,
                resumingRunID: nil,
                trialExchange: nil
            ),
            policy: ads
        )
        try runs.begin(adsRun)
    }

    private func seedChaptersFailure(message: String, context: ModelContext) throws {
        let record = EpisodeTranscriptAnalysisRecord(
            episodeID: Self.episodeID,
            podcastID: Self.feedURL,
            transcriptFingerprint: "leak-fingerprint",
            state: .failed,
            errorMessage: message
        )
        record.failureKind = .providerRejectedKey
        context.insert(record)
        try context.save()
    }

    private func seedDownload(fileStore: EpisodeDownloadFileStore, context: ModelContext) throws {
        let audioURL = try #require(URL(string: Self.audioURL))
        let relativePath = fileStore.relativePath(episodeID: Self.episodeID, sourceAudioURL: audioURL)
        let data = Data("downloaded episode".utf8)
        try fileStore.prepareDownloadsDirectory()
        try data.write(to: fileStore.fileURL(relativePath: relativePath), options: .atomic)
        let record = EpisodeDownloadRecord(
            episodeID: Self.episodeID,
            podcastID: Self.feedURL,
            sourceAudioURL: Self.audioURL,
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: Int64(data.count),
            bytesExpected: Int64(data.count),
            episodeTitle: "Leak Check Episode",
            podcastTitle: "Leak Check Show",
            duration: 30
        )
        record.sourceFileSHA256 = "recorded-sha"
        context.insert(record)
        try context.save()
    }

    private func seedTranscriptAndAnalysis(
        transcriptFileStore: EpisodeTranscriptFileStore,
        adAnalysisFileStore: EpisodeAdAnalysisFileStore,
        context: ModelContext
    ) throws {
        let segments = [
            OpenCastTranscriptSegment(id: 0, start: 0, end: 4, text: "Welcome back.", avgLogProbability: -0.1, noSpeechProbability: 0.01),
            OpenCastTranscriptSegment(
                id: 1,
                start: 4,
                end: 9,
                text: "This episode is brought to you by Example.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
        ]
        let transcript = EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: Self.episodeID,
            podcastID: Self.feedURL,
            sourceAudioURL: Self.audioURL,
            sourceFileByteCount: 123,
            sourceFileSHA256: "source",
            modelIdentifier: "model",
            modelVersion: "v1",
            modelTreeSHA256: "tree",
            languageCode: "en",
            audioDuration: 30,
            checkpoints: [],
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            timings: EpisodeTranscriptTimings(),
            createdAt: Date(timeIntervalSince1970: 1_779_999_990),
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        let transcriptRelativePath = transcriptFileStore.relativePath(episodeID: Self.episodeID, fingerprint: "transcript")
        try transcriptFileStore.write(transcript, relativePath: transcriptRelativePath)
        context.insert(EpisodeTranscriptRecord(
            episodeID: transcript.episodeID,
            podcastID: transcript.podcastID,
            sourceAudioURL: transcript.sourceAudioURL,
            sourceFileByteCount: transcript.sourceFileByteCount,
            sourceFileSHA256: transcript.sourceFileSHA256,
            modelIdentifier: transcript.modelIdentifier,
            modelVersion: transcript.modelVersion,
            modelTreeSHA256: transcript.modelTreeSHA256,
            languageCode: transcript.languageCode,
            state: .completed,
            audioDuration: transcript.audioDuration,
            completedDuration: transcript.audioDuration,
            checkpointCount: 0,
            transcriptRelativePath: transcriptRelativePath,
            createdAt: transcript.createdAt,
            updatedAt: transcript.updatedAt
        ))

        let fingerprint = adAnalysisFileStore.transcriptFingerprint(for: transcript)
        let analysis = EpisodeAdAnalysisDocument(
            schemaVersion: EpisodeAdAnalysisContract.schemaVersion,
            episodeID: transcript.episodeID,
            podcastID: transcript.podcastID,
            requestID: "request",
            transcriptFingerprint: fingerprint,
            transcriptUpdatedAt: transcript.updatedAt,
            transcriptSegmentCount: transcript.segments.count,
            model: "gemini-test",
            policy: EpisodeAdAnalysisContract.expectedPolicy,
            spans: [
                EpisodeAdAnalysisSpan(
                    id: 1,
                    kind: .hostReadAd,
                    label: "Span 1",
                    startSegmentID: 1,
                    endSegmentID: 1,
                    startTime: 4,
                    endTime: 9,
                    confidence: 0.9,
                    evidenceQuote: "brought to you by Example"
                ),
            ],
            warnings: [],
            usage: nil,
            createdAt: Date(timeIntervalSince1970: 1_780_000_001),
            updatedAt: Date(timeIntervalSince1970: 1_780_000_002)
        )
        let analysisRelativePath = adAnalysisFileStore.relativePath(
            episodeID: transcript.episodeID,
            transcriptFingerprint: fingerprint
        )
        try adAnalysisFileStore.write(analysis, relativePath: analysisRelativePath)
        context.insert(EpisodeAdAnalysisRecord(
            episodeID: transcript.episodeID,
            podcastID: transcript.podcastID,
            transcriptFingerprint: fingerprint,
            transcriptUpdatedAt: transcript.updatedAt,
            transcriptSegmentCount: transcript.segments.count,
            transcriptState: .completed,
            state: .completed,
            analysisRelativePath: analysisRelativePath,
            model: analysis.model,
            policy: analysis.policy,
            spanCount: analysis.spans.count,
            warningCount: 0,
            createdAt: analysis.createdAt,
            updatedAt: analysis.updatedAt
        ))
        try context.save()
    }
}

private actor CannedFileInspector: EpisodeDiagnosticsFileInspecting {
    func fileInfo(at url: URL) async -> EpisodeDiagnosticsFileInfo {
        EpisodeDiagnosticsFileInfo(exists: true, byteCount: 18)
    }

    func sha256(at url: URL) async throws -> String {
        "computed-sha"
    }

    func audioDuration(at url: URL) async throws -> TimeInterval {
        30
    }
}

private actor CannedNetworkProber: EpisodeDiagnosticsNetworkProbing {
    func headProbe(of url: URL) async -> EpisodeDiagnosticsHeadProbe {
        var probe = EpisodeDiagnosticsHeadProbe(requestedURL: url.absoluteString)
        probe.finalURL = url.absoluteString
        probe.statusCode = 200
        probe.mimeType = "audio/mpeg"
        return probe
    }
}
