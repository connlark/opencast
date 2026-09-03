import Foundation
import OpenCastCore
import OpenCastPlayback
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode diagnostics model")
struct EpisodeDiagnosticsModelTests {
    private static let episodeID = "episode"
    private static let feedURL = "https://example.com/feed.xml"
    private static let audioURL = "https://example.com/episode.mp3"

    @Test("Constructing the model performs no dependency work")
    func initTouchesNoDependencies() async throws {
        let fixture = try makeFixture()
        let fileInspector = SpyFileInspector()
        let prober = SpyNetworkProber()
        let dependencies = makeDependencies(
            fileInspector: fileInspector,
            prober: prober,
            counters: fixture.counters
        )

        _ = EpisodeDiagnosticsModel(episodeID: Self.episodeID, dependencies: dependencies)

        #expect(await fileInspector.fileInfoCalls == 0)
        #expect(await fileInspector.sha256Calls == 0)
        #expect(await fileInspector.durationCalls == 0)
        #expect(await prober.probedURLs.isEmpty)
        #expect(fixture.counters.playbackSnapshotCalls == 0)
        #expect(fixture.counters.ensureCalls == 0)
        #expect(fixture.counters.prepareCalls == 0)
    }

    @Test("Load populates every section from seeded records, documents, and probes")
    func loadPopulatesSeededSections() async throws {
        let fixture = try makeFixture()
        try seedCompletedTranscriptAndAnalysis(in: fixture)
        let downloadRelativePath = try seedCompletedDownload(in: fixture)
        await loadStores(in: fixture)

        let fileInspector = SpyFileInspector()
        let prober = SpyNetworkProber()
        let dependencies = makeDependencies(
            fileInspector: fileInspector,
            prober: prober,
            counters: fixture.counters
        )
        let model = EpisodeDiagnosticsModel(episodeID: Self.episodeID, dependencies: dependencies)

        await model.load(appModel: fixture.appModel)

        #expect(rowValue(model.state(for: .episode), "Feed URL") == Self.feedURL)
        #expect(rowValue(model.state(for: .episode), "Enclosure URL") == Self.audioURL)
        #expect(rowValue(model.state(for: .episode), "Last Refresh") == "Never")

        let downloadState = model.state(for: .download)
        #expect({ if case .loaded = downloadState { true } else { false } }())
        let downloadFileURL = try #require(rowValue(downloadState, "File URL"))
        #expect(downloadFileURL.hasPrefix("file://"))
        #expect(downloadFileURL.contains(downloadRelativePath))
        #expect(rowValue(downloadState, "Computed SHA-256") == "computed-sha")
        #expect(rowValue(downloadState, "Local Media Duration") == "5200.000s")

        #expect(rowValue(model.state(for: .transcript), "Model") == "model")
        #expect(rowValue(model.state(for: .transcript), "Segments") == "2")
        #expect(rowValue(model.state(for: .adAnalysis), "Current For Transcript") == "Yes")
        #expect(rowValue(model.state(for: .adAnalysis), "Policy") == EpisodeAdAnalysisContract.expectedPolicy)

        let spansState = model.state(for: .adSpans)
        let spanRow = try #require(rowValue(spansState, "Span #1 — Host Read"))
        #expect(spanRow.contains("auto-skip"))
        #expect(spanRow.contains("confidence 0.9"))

        let matrixState = model.state(for: .zoneMatrix)
        #expect(rowValue(matrixState, "Unclamped Auto Zones") != nil)
        #expect(rowValue(matrixState, "RSS Duration") == "30.000s")

        let probedURLs = await prober.probedURLs.map(\.absoluteString)
        #expect(probedURLs.count == 2)
        #expect(Set(probedURLs) == [Self.feedURL, Self.audioURL])
        #expect(rowValue(model.state(for: .feedProbe), "Status") == "200")
        #expect(rowValue(model.state(for: .enclosureProbe), "Status") == "200")

        let report = model.reportText()
        #expect(report.contains("== Zone Matrix =="))
        #expect(report.contains(downloadFileURL))
        #expect(report.contains(Self.audioURL))
    }

    @Test("A download with no recorded hash skips the full-file hash pass")
    func noRecordedHashSkipsComputedSHA() async throws {
        let fixture = try makeFixture()
        try seedCompletedDownload(in: fixture, sourceFileSHA256: "")
        await loadStores(in: fixture)

        let fileInspector = SpyFileInspector()
        let dependencies = makeDependencies(
            fileInspector: fileInspector,
            prober: SpyNetworkProber(),
            counters: fixture.counters
        )
        let model = EpisodeDiagnosticsModel(episodeID: Self.episodeID, dependencies: dependencies)

        await model.load(appModel: fixture.appModel)

        #expect(await fileInspector.sha256Calls == 0)
        #expect(rowValue(model.state(for: .download), "Computed SHA-256") == nil)
        #expect(rowValue(model.state(for: .download), "Local Media Duration") == "5200.000s")
    }

    @Test("A hashing failure and a corrupt analysis document stay local to their sections")
    func sectionFailuresStayLocal() async throws {
        let fixture = try makeFixture()
        let seeded = try seedCompletedTranscriptAndAnalysis(in: fixture)
        try seedCompletedDownload(in: fixture)
        try Data("not json".utf8).write(
            to: fixture.adAnalysisFileStore.fileURL(relativePath: seeded.analysisRelativePath),
            options: .atomic
        )
        await loadStores(in: fixture)

        let fileInspector = SpyFileInspector(sha256: .failure(CocoaError(.fileReadUnknown)))
        let dependencies = makeDependencies(
            fileInspector: fileInspector,
            prober: SpyNetworkProber(),
            counters: fixture.counters
        )
        let model = EpisodeDiagnosticsModel(episodeID: Self.episodeID, dependencies: dependencies)

        await model.load(appModel: fixture.appModel)

        let shaValue = try #require(rowValue(model.state(for: .download), "Computed SHA-256"))
        #expect(shaValue.hasPrefix("Failed:"))
        #expect(rowValue(model.state(for: .download), "Local Media Duration") == "5200.000s")
        #expect(rowValue(model.state(for: .adAnalysis), "Document Error") != nil)
        #expect(rowValue(model.state(for: .adSpans), "Status") != nil)
        #expect(rowValue(model.state(for: .zoneMatrix), "Status") != nil)
        #expect(rowValue(model.state(for: .transcript), "Segments") == "2")
        #expect(rowValue(model.state(for: .episode), "Feed URL") == Self.feedURL)
    }

    @Test("Playback section reports when the episode is not the loaded one")
    func playbackSectionWhenEpisodeNotLoaded() async throws {
        let fixture = try makeFixture()
        try seedCompletedDownload(in: fixture)
        await loadStores(in: fixture)
        let model = EpisodeDiagnosticsModel(
            episodeID: Self.episodeID,
            dependencies: makeDependencies(
                fileInspector: SpyFileInspector(),
                prober: SpyNetworkProber(),
                counters: fixture.counters
            )
        )

        await model.load(appModel: fixture.appModel)

        #expect(rowValue(model.state(for: .playback), "Status") == "Episode not currently loaded.")
        #expect(rowValue(model.state(for: .zoneMatrix), "Status") != nil)
    }

    @Test("Zone matrix compares derived zones against the installed player zones")
    func zoneMatrixComparesInstalledZones() async throws {
        let fixture = try makeFixture()
        try seedCompletedTranscriptAndAnalysis(in: fixture)
        await loadStores(in: fixture)

        var snapshot = EpisodeDiagnosticsPlaybackSnapshot.disconnected
        snapshot.loadedEpisodeID = Self.episodeID
        snapshot.duration = 30
        snapshot.installedAutoSkipZones = [PlaybackSkipZone(id: 1, startTime: 4, endTime: 9)]
        let model = EpisodeDiagnosticsModel(
            episodeID: Self.episodeID,
            dependencies: makeDependencies(
                fileInspector: SpyFileInspector(),
                prober: SpyNetworkProber(),
                counters: fixture.counters,
                snapshot: snapshot
            )
        )

        await model.load(appModel: fixture.appModel)

        #expect(rowValue(model.state(for: .zoneMatrix), "Player vs Installed") == "Match")
        #expect(rowValue(model.state(for: .playback), "Installed Auto Zones") == "#1 4.000s–9.000s")

        var mismatchSnapshot = snapshot
        mismatchSnapshot.installedAutoSkipZones = []
        let mismatchModel = EpisodeDiagnosticsModel(
            episodeID: Self.episodeID,
            dependencies: makeDependencies(
                fileInspector: SpyFileInspector(),
                prober: SpyNetworkProber(),
                counters: fixture.counters,
                snapshot: mismatchSnapshot
            )
        )
        await mismatchModel.load(appModel: fixture.appModel)
        #expect(rowValue(mismatchModel.state(for: .zoneMatrix), "Player vs Installed") == "MISMATCH")
    }

    @Test("Report text renders loaded, partial, and loading sections")
    func reportTextRendersAllStates() {
        let section = EpisodeDiagnosticsSection(rows: [("Label", "Value")], footnote: "A footnote.")
        let text = EpisodeDiagnosticsReportText.make(
            episodeID: "ep-1",
            episodeTitle: "Deterministic UI Episode",
            podcastTitle: "UI Test Show",
            sections: [
                (.report, .loaded(section)),
                (.episode, .partial(section)),
                (.download, .loading),
            ]
        )

        #expect(text.hasPrefix("OpenCast Episode Diagnostics"))
        #expect(text.contains("Episode: Deterministic UI Episode — UI Test Show"))
        #expect(text.contains("Episode ID: ep-1"))
        #expect(text.contains("== Report =="))
        #expect(text.contains("Label: Value"))
        #expect(text.contains("Note: A footnote."))
        #expect(text.contains("(some values still loading)"))
        #expect(text.contains("(still loading)"))
    }

    @Test("Share presents immediately when a valid completed download exists")
    func sharePresentsImmediatelyForCompletedDownload() async throws {
        let fixture = try makeFixture()
        try seedCompletedDownload(in: fixture)
        await loadStores(in: fixture)
        let model = EpisodeDiagnosticsModel(
            episodeID: Self.episodeID,
            dependencies: makeDependencies(
                fileInspector: SpyFileInspector(),
                prober: SpyNetworkProber(),
                counters: fixture.counters
            )
        )

        model.shareMP3(appModel: fixture.appModel, modelContext: fixture.context)

        #expect(model.presentedShareFile != nil)
        #expect(model.mp3ShareState == .idle)
        #expect(fixture.counters.prepareCalls == 1)
        #expect(fixture.counters.ensureCalls == 0)

        model.shareSheetDismissed()
        #expect(fixture.counters.cleanUpCalls == 1)
        model.shareSheetDismissed()
        #expect(fixture.counters.cleanUpCalls == 1)
    }

    @Test("Re-sharing while a share is active cleans up the replaced share file")
    func reShareCleansUpReplacedShareFile() async throws {
        let fixture = try makeFixture()
        try seedCompletedDownload(in: fixture)
        await loadStores(in: fixture)
        let model = EpisodeDiagnosticsModel(
            episodeID: Self.episodeID,
            dependencies: makeDependencies(
                fileInspector: SpyFileInspector(),
                prober: SpyNetworkProber(),
                counters: fixture.counters
            )
        )

        model.shareMP3(appModel: fixture.appModel, modelContext: fixture.context)
        model.shareMP3(appModel: fixture.appModel, modelContext: fixture.context)

        #expect(fixture.counters.prepareCalls == 2)
        #expect(fixture.counters.cleanUpCalls == 1)

        model.shareSheetDismissed()
        #expect(fixture.counters.cleanUpCalls == 2)
    }

    @Test("A file-access failure surfaces as a check error, not a missing file")
    func fileAccessFailureSurfacesAsCheckError() async throws {
        let fixture = try makeFixture()
        try seedCompletedDownload(in: fixture)
        await loadStores(in: fixture)
        let fileInspector = SpyFileInspector(
            fileInfo: EpisodeDiagnosticsFileInfo(
                exists: false,
                byteCount: nil,
                errorDescription: "not permitted"
            )
        )
        let model = EpisodeDiagnosticsModel(
            episodeID: Self.episodeID,
            dependencies: makeDependencies(
                fileInspector: fileInspector,
                prober: SpyNetworkProber(),
                counters: fixture.counters
            )
        )

        await model.load(appModel: fixture.appModel)

        let downloadState = model.state(for: .download)
        #expect(rowValue(downloadState, "File Check") == "Failed: not permitted")
        #expect(rowValue(downloadState, "File Exists") == nil)
        #expect(await fileInspector.sha256Calls == 0)
    }

    @Test("Share waits for the reused download and presents when it completes")
    func shareWaitsForDownloadThenPresents() async throws {
        let fixture = try makeFixture()
        try seedFailedDownload(in: fixture)
        await loadStores(in: fixture)
        let gate = ShareGate()
        let completedRecord = try makeStandaloneCompletedRecord(in: fixture)
        let model = EpisodeDiagnosticsModel(
            episodeID: Self.episodeID,
            dependencies: makeDependencies(
                fileInspector: SpyFileInspector(),
                prober: SpyNetworkProber(),
                counters: fixture.counters,
                ensure: { _, _, _ in
                    await gate.wait()
                    return completedRecord
                }
            )
        )

        model.shareMP3(appModel: fixture.appModel, modelContext: fixture.context)
        #expect(model.mp3ShareState == .waitingForDownload)
        #expect(await waitUntil { fixture.counters.ensureCalls == 1 })
        #expect(model.presentedShareFile == nil)

        gate.release()
        #expect(await waitUntil { model.presentedShareFile != nil })
        #expect(model.mp3ShareState == .idle)
        #expect(fixture.counters.prepareCalls == 1)
    }

    @Test("Dismissing diagnostics stops the wait and never presents later")
    func dismissStopsWaitWithoutPresenting() async throws {
        let fixture = try makeFixture()
        try seedFailedDownload(in: fixture)
        await loadStores(in: fixture)
        let model = EpisodeDiagnosticsModel(
            episodeID: Self.episodeID,
            dependencies: makeDependencies(
                fileInspector: SpyFileInspector(),
                prober: SpyNetworkProber(),
                counters: fixture.counters,
                ensure: { _, _, _ in
                    try await Task.sleep(for: .seconds(60))
                    throw DownloadStore.CompletedDownloadError.fileMissing
                }
            )
        )

        model.shareMP3(appModel: fixture.appModel, modelContext: fixture.context)
        #expect(model.mp3ShareState == .waitingForDownload)

        model.handleDisappear()

        #expect(await waitUntil { model.mp3ShareState == .idle })
        #expect(model.presentedShareFile == nil)
        #expect(fixture.counters.prepareCalls == 0)
    }

    @Test("Explicit cancel stops the underlying store download")
    func explicitCancelStopsStoreDownload() async throws {
        let fixture = try makeFixture()
        try seedFailedDownload(in: fixture)
        await loadStores(in: fixture)
        let model = EpisodeDiagnosticsModel(
            episodeID: Self.episodeID,
            dependencies: makeDependencies(
                fileInspector: SpyFileInspector(),
                prober: SpyNetworkProber(),
                counters: fixture.counters,
                ensure: { appModel, episode, modelContext in
                    try await appModel.downloads.ensureCompletedDownload(
                        for: episode,
                        modelContext: modelContext
                    ) {
                        try Task.checkCancellation()
                    }
                }
            )
        )

        model.shareMP3(appModel: fixture.appModel, modelContext: fixture.context)
        #expect(await waitUntil {
            fixture.appModel.downloads.record(for: Self.episodeID)?.state == .downloading
        })

        model.cancelSharedDownload(appModel: fixture.appModel, modelContext: fixture.context)

        #expect(await waitUntil { model.mp3ShareState == .idle })
        #expect(fixture.appModel.downloads.record(for: Self.episodeID) == nil)
        #expect(model.presentedShareFile == nil)
    }

    @Test("A download that cannot complete surfaces a share failure")
    func failedEnsureSurfacesShareFailure() async throws {
        let fixture = try makeFixture()
        try seedFailedDownload(in: fixture)
        await loadStores(in: fixture)
        let model = EpisodeDiagnosticsModel(
            episodeID: Self.episodeID,
            dependencies: makeDependencies(
                fileInspector: SpyFileInspector(),
                prober: SpyNetworkProber(),
                counters: fixture.counters,
                ensure: { _, _, _ in
                    throw DownloadStore.CompletedDownloadError.notCompleted(state: .failed, errorMessage: "boom")
                }
            )
        )

        model.shareMP3(appModel: fixture.appModel, modelContext: fixture.context)

        #expect(await waitUntil { model.mp3ShareState == .failed("boom") })
        #expect(model.presentedShareFile == nil)
    }

    // MARK: - Fixture

    private struct Fixture {
        let context: ModelContext
        let appModel: OpenCastAppModel
        let downloadFileStore: EpisodeDownloadFileStore
        let transcriptFileStore: EpisodeTranscriptFileStore
        let adAnalysisFileStore: EpisodeAdAnalysisFileStore
        let counters: DependencyCounters
    }

    private func makeFixture() throws -> Fixture {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let temporaryDirectory = try makeTemporaryDirectory()
        let downloadFileStore = EpisodeDownloadFileStore(baseDirectory: temporaryDirectory)
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: temporaryDirectory)
        let adAnalysisFileStore = EpisodeAdAnalysisFileStore(baseDirectory: temporaryDirectory)
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            downloads: DownloadStore(
                downloader: RecordingHangingEpisodeAudioDownloader(),
                fileStore: downloadFileStore
            ),
            transcriptions: EpisodeTranscriptionStore(fileStore: transcriptFileStore),
            adAnalyses: EpisodeAdAnalysisStore(
                client: UnusedEpisodeAdAnalysisClient(),
                fileStore: adAnalysisFileStore
            ),
            allowsAutomaticFeedRefresh: false
        )
        return Fixture(
            context: context,
            appModel: appModel,
            downloadFileStore: downloadFileStore,
            transcriptFileStore: transcriptFileStore,
            adAnalysisFileStore: adAnalysisFileStore,
            counters: DependencyCounters()
        )
    }

    private func loadStores(in fixture: Fixture) async {
        await fixture.appModel.downloads.load(modelContext: fixture.context)
        fixture.appModel.loadLocalTranscriptionState(modelContext: fixture.context)
    }

    private func makeDependencies(
        fileInspector: any EpisodeDiagnosticsFileInspecting,
        prober: any EpisodeDiagnosticsNetworkProbing,
        counters: DependencyCounters,
        snapshot: EpisodeDiagnosticsPlaybackSnapshot = .disconnected,
        ensure: (@MainActor (OpenCastAppModel, EpisodeListItemSnapshot, ModelContext) async throws -> EpisodeDownloadRecord)? = nil
    ) -> EpisodeDiagnosticsDependencies {
        EpisodeDiagnosticsDependencies(
            fileInspector: fileInspector,
            networkProber: prober,
            playbackSnapshot: { _ in
                counters.playbackSnapshotCalls += 1
                return snapshot
            },
            ensureCompletedDownload: { appModel, episode, modelContext in
                counters.ensureCalls += 1
                guard let ensure else {
                    throw DownloadStore.CompletedDownloadError.fileMissing
                }
                return try await ensure(appModel, episode, modelContext)
            },
            prepareShareFile: { source, _, _ in
                counters.prepareCalls += 1
                return EpisodeDiagnosticsShareFile(url: source, temporaryDirectoryURL: nil)
            },
            cleanUpShareFile: { _ in
                counters.cleanUpCalls += 1
            }
        )
    }

    @discardableResult
    private func seedCompletedTranscriptAndAnalysis(
        in fixture: Fixture
    ) throws -> (analysisRelativePath: String, transcript: EpisodeTranscriptDocument) {
        let transcript = makeTranscriptDocument()
        let transcriptRelativePath = fixture.transcriptFileStore.relativePath(
            episodeID: transcript.episodeID,
            fingerprint: "transcript"
        )
        try fixture.transcriptFileStore.write(transcript, relativePath: transcriptRelativePath)
        fixture.context.insert(EpisodeTranscriptRecord(
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

        let fingerprint = fixture.adAnalysisFileStore.transcriptFingerprint(for: transcript)
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
        let analysisRelativePath = fixture.adAnalysisFileStore.relativePath(
            episodeID: transcript.episodeID,
            transcriptFingerprint: fingerprint
        )
        try fixture.adAnalysisFileStore.write(analysis, relativePath: analysisRelativePath)
        fixture.context.insert(EpisodeAdAnalysisRecord(
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
        try fixture.context.save()
        return (analysisRelativePath, transcript)
    }

    @discardableResult
    private func seedCompletedDownload(
        in fixture: Fixture,
        sourceFileSHA256: String = "recorded-sha"
    ) throws -> String {
        let relativePath = fixture.downloadFileStore.relativePath(
            episodeID: Self.episodeID,
            sourceAudioURL: URL(string: Self.audioURL)!
        )
        let fileURL = fixture.downloadFileStore.fileURL(relativePath: relativePath)
        let data = Data("downloaded episode".utf8)
        try fixture.downloadFileStore.prepareDownloadsDirectory()
        try data.write(to: fileURL, options: .atomic)
        let record = EpisodeDownloadRecord(
            episodeID: Self.episodeID,
            podcastID: Self.feedURL,
            sourceAudioURL: Self.audioURL,
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: Int64(data.count),
            bytesExpected: Int64(data.count),
            episodeTitle: "Deterministic Episode",
            podcastTitle: "Example Show",
            duration: 30
        )
        record.sourceFileSHA256 = sourceFileSHA256
        fixture.context.insert(record)
        try fixture.context.save()
        return relativePath
    }

    private func seedFailedDownload(in fixture: Fixture) throws {
        fixture.context.insert(EpisodeDownloadRecord(
            episodeID: Self.episodeID,
            podcastID: Self.feedURL,
            sourceAudioURL: Self.audioURL,
            state: .failed,
            errorMessage: "network dropped",
            episodeTitle: "Deterministic Episode",
            podcastTitle: "Example Show",
            duration: 30
        ))
        try fixture.context.save()
    }

    private func makeStandaloneCompletedRecord(in fixture: Fixture) throws -> EpisodeDownloadRecord {
        let relativePath = fixture.downloadFileStore.relativePath(
            episodeID: "standalone",
            sourceAudioURL: URL(string: Self.audioURL)!
        )
        let fileURL = fixture.downloadFileStore.fileURL(relativePath: relativePath)
        try fixture.downloadFileStore.prepareDownloadsDirectory()
        try Data("late download".utf8).write(to: fileURL, options: .atomic)
        return EpisodeDownloadRecord(
            episodeID: Self.episodeID,
            podcastID: Self.feedURL,
            sourceAudioURL: Self.audioURL,
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: 13,
            bytesExpected: 13
        )
    }

    private func makeTranscriptDocument() -> EpisodeTranscriptDocument {
        let segments = [
            OpenCastTranscriptSegment(
                id: 0,
                start: 0,
                end: 4,
                text: "Welcome back.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 1,
                start: 4,
                end: 9,
                text: "This episode is brought to you by Example.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
        ]
        return EpisodeTranscriptDocument(
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
    }

    private func rowValue(_ state: EpisodeDiagnosticsSectionState, _ label: String) -> String? {
        state.section?.rows.first { $0.label == label }?.value
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastDiagnosticsModelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

@MainActor
private final class DependencyCounters {
    var playbackSnapshotCalls = 0
    var ensureCalls = 0
    var prepareCalls = 0
    var cleanUpCalls = 0
}

@MainActor
private final class ShareGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private extension EpisodeDiagnosticsPlaybackSnapshot {
    static let disconnected = EpisodeDiagnosticsPlaybackSnapshot(
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
}

private actor SpyFileInspector: EpisodeDiagnosticsFileInspecting {
    private(set) var fileInfoCalls = 0
    private(set) var sha256Calls = 0
    private(set) var durationCalls = 0
    private let fileInfoResult: EpisodeDiagnosticsFileInfo
    private let sha256Result: Result<String, any Error>
    private let durationResult: Result<TimeInterval, any Error>

    init(
        fileInfo: EpisodeDiagnosticsFileInfo = EpisodeDiagnosticsFileInfo(exists: true, byteCount: 18),
        sha256: Result<String, any Error> = .success("computed-sha"),
        duration: Result<TimeInterval, any Error> = .success(5_200)
    ) {
        fileInfoResult = fileInfo
        sha256Result = sha256
        durationResult = duration
    }

    func fileInfo(at url: URL) async -> EpisodeDiagnosticsFileInfo {
        fileInfoCalls += 1
        return fileInfoResult
    }

    func sha256(at url: URL) async throws -> String {
        sha256Calls += 1
        return try sha256Result.get()
    }

    func audioDuration(at url: URL) async throws -> TimeInterval {
        durationCalls += 1
        return try durationResult.get()
    }
}

private actor SpyNetworkProber: EpisodeDiagnosticsNetworkProbing {
    private(set) var probedURLs: [URL] = []

    func headProbe(of url: URL) async -> EpisodeDiagnosticsHeadProbe {
        probedURLs.append(url)
        var probe = EpisodeDiagnosticsHeadProbe(requestedURL: url.absoluteString)
        probe.finalURL = url.absoluteString
        probe.statusCode = 200
        probe.mimeType = "audio/mpeg"
        return probe
    }
}

private struct UnusedEpisodeAdAnalysisClient: EpisodeAdAnalysisClient {
    func analyze(_ request: EpisodeAdAnalysisAPIRequest) async throws -> EpisodeAdAnalysisSubmitOutcome {
        throw EpisodeAdAnalysisError.clientDisabled
    }

    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome {
        throw EpisodeAdAnalysisError.clientDisabled
    }
}
