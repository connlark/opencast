import Foundation
import SwiftData
import UIKit

/// Sheet-scoped loader for the Episode Diagnostics report. Construction does
/// no work at all; every read, file check, and probe starts from `load`,
/// which the sheet's `.task` drives, so nothing runs until the sheet opens
/// and everything cancels when it closes. The audio share flow runs in its own
/// task because dismissing diagnostics must stop the *wait* without touching
/// a download the user asked for.
@Observable
final class EpisodeDiagnosticsModel {
    let episodeID: String

    private(set) var sectionStates: [EpisodeDiagnosticsSectionID: EpisodeDiagnosticsSectionState] = [:]
    private(set) var episodeTitle: String?
    private(set) var podcastTitle: String?
    private(set) var loadGeneration = 0
    private(set) var mp3ShareState: EpisodeDiagnosticsMP3ShareState = .idle
    var presentedShareFile: EpisodeDiagnosticsShareFile?

    /// Live dependencies are built on first use, not in init: the presenting
    /// closure re-evaluates the sheet's initializer per body pass and @State
    /// discards every model but the first, so an eager default would allocate
    /// (and leak until deinit) a fresh probe URLSession per evaluation.
    var dependencies: EpisodeDiagnosticsDependencies {
        if let injectedOrBuiltDependencies {
            return injectedOrBuiltDependencies
        }
        let live = EpisodeDiagnosticsDependencies.live()
        injectedOrBuiltDependencies = live
        return live
    }

    @ObservationIgnored private var injectedOrBuiltDependencies: EpisodeDiagnosticsDependencies?
    @ObservationIgnored private var reportRevision = 0
    @ObservationIgnored private var cachedReport: (revision: Int, text: String)?
    @ObservationIgnored private var shareTask: Task<Void, Never>?
    @ObservationIgnored private var activeShareFile: EpisodeDiagnosticsShareFile?
    @ObservationIgnored private var isDismissed = false

    init(episodeID: String, dependencies: EpisodeDiagnosticsDependencies? = nil) {
        self.episodeID = episodeID
        injectedOrBuiltDependencies = dependencies
    }

    func state(for id: EpisodeDiagnosticsSectionID) -> EpisodeDiagnosticsSectionState {
        sectionStates[id] ?? .loading
    }

    func requestRefresh() {
        loadGeneration += 1
    }

    // MARK: - Loading

    func load(appModel: OpenCastAppModel) async {
        let generatedAt = Date.now
        for id in EpisodeDiagnosticsSectionID.allCases {
            setSection(id, .loading)
        }

        let episode = appModel.episodeSnapshot(for: episodeID)
        episodeTitle = episode?.title
        podcastTitle = episode?.podcastTitle
        let playbackSnapshot = dependencies.playbackSnapshot(appModel)

        setSection(.report, .loaded(Self.reportSection(generatedAt: generatedAt)))
        setSection(.episode, .loaded(episodeSection(appModel: appModel, episode: episode)))
        setSection(
            .progressAndSettings,
            .loaded(progressAndSettingsSection(appModel: appModel, episode: episode))
        )
        setSection(.playback, .loaded(playbackSection(snapshot: playbackSnapshot)))
        setSection(.chaptersSummary, .loaded(chaptersSummarySection(appModel: appModel)))

        let downloadRecord = appModel.downloads.record(for: episodeID)
        let downloadFileURL = downloadRecord.flatMap { appModel.downloads.diagnosticsFileURL(for: $0) }
        if let downloadRecord {
            setSection(
                .download,
                .partial(downloadSection(
                    record: downloadRecord,
                    fileURL: downloadFileURL,
                    byteProgress: appModel.downloads.byteProgress(for: episodeID),
                    enrichment: nil
                ))
            )
        } else {
            setSection(.download, .loaded(EpisodeDiagnosticsSection(rows: [("Status", "No download record.")])))
        }

        let transcriptRecord = appModel.transcriptions.record(for: episodeID)
        let transcriptFileURL = appModel.transcriptions.diagnosticsDocumentFileURL(for: episodeID)
        if let transcriptRecord {
            setSection(
                .transcript,
                .partial(transcriptSection(record: transcriptRecord, fileURL: transcriptFileURL, outcome: nil))
            )
        } else {
            setSection(.transcript, .loaded(EpisodeDiagnosticsSection(rows: [("Status", "No transcript record.")])))
        }

        let adRecord = appModel.adAnalyses.record(for: episodeID)
        let adFileURL = appModel.adAnalyses.diagnosticsDocumentFileURL(for: episodeID)
        if let adRecord {
            setSection(
                .adAnalysis,
                .partial(adAnalysisSection(
                    record: adRecord,
                    fileURL: adFileURL,
                    outcome: nil,
                    isCurrentForTranscript: nil
                ))
            )
        } else {
            let missing = EpisodeDiagnosticsSection(rows: [("Status", "No ad analysis record.")])
            setSection(.adAnalysis, .loaded(missing))
            setSection(.adSpans, .loaded(missing))
            setSection(.zoneMatrix, .loaded(missing))
        }

        let hasTranscriptRecord = transcriptRecord != nil
        let hasAdRecord = adRecord != nil
        let storedDownloadSHA256 = downloadRecord?.sourceFileSHA256

        await withTaskGroup(of: LoadStep.self) { group in
            group.addTask {
                .download(await self.enrichDownload(
                    fileURL: downloadFileURL,
                    storedSHA256: storedDownloadSHA256
                ))
            }
            group.addTask {
                .transcript(await self.loadTranscriptDocument(
                    appModel: appModel,
                    hasRecord: hasTranscriptRecord,
                    fileURL: transcriptFileURL
                ))
            }
            group.addTask {
                .adAnalysis(await self.loadAdDocument(
                    appModel: appModel,
                    hasRecord: hasAdRecord,
                    fileURL: adFileURL
                ))
            }
            group.addTask {
                .feedProbe(await self.probeSection(
                    urlString: episode?.podcastID,
                    footnote: "Live HEAD result for the canonical feed URL. RSS fields in the Episode section are parsed values stored at refresh time, not this response."
                ))
            }
            group.addTask {
                .enclosureProbe(await self.probeSection(
                    urlString: episode?.audioURL,
                    footnote: "Live HEAD result for the RSS enclosure URL. The download may have used a different assembly of the same episode."
                ))
            }

            var enrichment: DownloadEnrichment?
            var hasEnrichment = false
            var transcript: DocumentOutcome<EpisodeTranscriptDocument>?
            var ad: DocumentOutcome<EpisodeAdAnalysisDocument>?
            var didPublishAdAnalysis = false
            var didPublishZoneMatrix = false

            // The ad-analysis section compares against the transcript document
            // and the zone matrix additionally needs the local media duration,
            // so those two wait for their inputs; everything else publishes
            // the moment its own step lands.
            @MainActor func publishSettledAdSections() async {
                guard let adRecord, let ad, let transcript else {
                    return
                }
                if !didPublishAdAnalysis {
                    didPublishAdAnalysis = true
                    // The currency verdict normalizes and fingerprints the
                    // whole transcript — off-caller, never on the MainActor
                    // while the sheet is rendering.
                    let isCurrent: Bool? = if let adDocument = ad.document,
                        let transcriptDocument = transcript.document {
                        await appModel.adAnalyses.isCurrentAnalysisDocumentOffCaller(
                            adDocument,
                            for: transcriptDocument
                        )
                    } else {
                        nil
                    }
                    guard !Task.isCancelled else {
                        return
                    }
                    setSection(
                        .adAnalysis,
                        .loaded(adAnalysisSection(
                            record: adRecord,
                            fileURL: adFileURL,
                            outcome: ad,
                            isCurrentForTranscript: isCurrent
                        ))
                    )
                }
                if hasEnrichment, !didPublishZoneMatrix {
                    didPublishZoneMatrix = true
                    setSection(
                        .zoneMatrix,
                        .loaded(zoneMatrixSection(
                            outcome: ad,
                            rssDuration: episode?.duration,
                            transcriptDuration: transcriptDuration(record: transcriptRecord, document: transcript.document),
                            localMediaDuration: enrichment?.localDuration,
                            snapshot: playbackSnapshot
                        ))
                    )
                }
            }

            for await step in group {
                guard !Task.isCancelled else {
                    return
                }
                switch step {
                case .download(let downloadEnrichment):
                    enrichment = downloadEnrichment
                    hasEnrichment = true
                    if let downloadRecord {
                        setSection(
                            .download,
                            .loaded(downloadSection(
                                record: downloadRecord,
                                fileURL: downloadFileURL,
                                byteProgress: appModel.downloads.byteProgress(for: episodeID),
                                enrichment: downloadEnrichment
                            ))
                        )
                    }
                    await publishSettledAdSections()
                case .transcript(let outcome):
                    transcript = outcome
                    if let transcriptRecord {
                        setSection(
                            .transcript,
                            .loaded(transcriptSection(
                                record: transcriptRecord,
                                fileURL: transcriptFileURL,
                                outcome: outcome
                            ))
                        )
                    }
                    await publishSettledAdSections()
                case .adAnalysis(let outcome):
                    ad = outcome
                    if adRecord != nil {
                        setSection(.adSpans, .loaded(adSpansSection(outcome: outcome)))
                    }
                    await publishSettledAdSections()
                case .feedProbe(let section):
                    setSection(.feedProbe, .loaded(section))
                case .enclosureProbe(let section):
                    setSection(.enclosureProbe, .loaded(section))
                }
            }
        }
    }

    private nonisolated enum LoadStep: Sendable {
        case download(DownloadEnrichment?)
        case transcript(DocumentOutcome<EpisodeTranscriptDocument>)
        case adAnalysis(DocumentOutcome<EpisodeAdAnalysisDocument>)
        case feedProbe(EpisodeDiagnosticsSection)
        case enclosureProbe(EpisodeDiagnosticsSection)
    }

    // MARK: - Report

    func reportText() -> String {
        if let cachedReport, cachedReport.revision == reportRevision {
            return cachedReport.text
        }
        let text = EpisodeDiagnosticsReportText.make(
            episodeID: episodeID,
            episodeTitle: episodeTitle,
            podcastTitle: podcastTitle,
            sections: EpisodeDiagnosticsSectionID.allCases.map { ($0, state(for: $0)) }
        )
        cachedReport = (reportRevision, text)
        return text
    }

    func copyReport() {
        UIPasteboard.general.string = reportText()
    }

    // MARK: - Download & Share Audio

    func shareMP3(appModel: OpenCastAppModel, modelContext: ModelContext) {
        guard shareTask == nil else {
            return
        }
        guard let episode = appModel.episodeSnapshot(for: episodeID) else {
            mp3ShareState = .failed("Episode is no longer available.")
            return
        }

        if let record = appModel.downloads.record(for: episodeID),
           record.state == .completed,
           appModel.downloads.downloadedFileExists(for: record),
           let fileURL = appModel.downloads.localFileURL(for: record) {
            mp3ShareState = .idle
            presentShare(source: fileURL, episode: episode)
            return
        }

        mp3ShareState = .waitingForDownload
        shareTask = Task {
            defer {
                shareTask = nil
            }
            do {
                let record = try await dependencies.ensureCompletedDownload(appModel, episode, modelContext)
                guard !Task.isCancelled, !isDismissed else {
                    mp3ShareState = .idle
                    return
                }
                guard let fileURL = appModel.downloads.localFileURL(for: record) else {
                    mp3ShareState = .failed("Downloaded file is unavailable.")
                    return
                }
                mp3ShareState = .idle
                presentShare(source: fileURL, episode: episode)
            } catch is CancellationError {
                mp3ShareState = .idle
            } catch let error as DownloadStore.CompletedDownloadError {
                switch error {
                case .fileMissing:
                    mp3ShareState = .failed("Downloaded file is missing.")
                case .notCompleted(_, let errorMessage):
                    mp3ShareState = .failed(errorMessage ?? "The download did not complete.")
                }
            } catch {
                mp3ShareState = .failed(error.localizedDescription)
            }
        }
    }

    /// Explicit cancel: stops the app download itself, not only this sheet's
    /// wait for it.
    func cancelSharedDownload(appModel: OpenCastAppModel, modelContext: ModelContext) {
        shareTask?.cancel()
        appModel.downloads.cancelDownload(episodeID: episodeID, modelContext: modelContext)
        mp3ShareState = .idle
    }

    func shareSheetDismissed() {
        guard let activeShareFile else {
            return
        }
        dependencies.cleanUpShareFile(activeShareFile)
        self.activeShareFile = nil
    }

    /// Dismissal stops waiting and blocks a later automatic share
    /// presentation, but deliberately leaves the download itself running.
    func handleDisappear() {
        isDismissed = true
        shareTask?.cancel()
        presentedShareFile = nil
        shareSheetDismissed()
    }

    private func presentShare(source: URL, episode: EpisodeListItemSnapshot) {
        // A re-share while a share is still active would otherwise strand the
        // previous hard-link directory, keeping the episode's disk blocks
        // alive even after the download itself is deleted.
        if let activeShareFile {
            dependencies.cleanUpShareFile(activeShareFile)
        }
        let shareFile = dependencies.prepareShareFile(source, episode.podcastTitle, episode.title)
        activeShareFile = shareFile
        presentedShareFile = shareFile
    }

    // MARK: - Async enrichment

    nonisolated struct DownloadEnrichment: Sendable, Equatable {
        var fileInfo: EpisodeDiagnosticsFileInfo?
        var computedSHA256: String?
        var sha256ErrorDescription: String?
        var localDuration: TimeInterval?
        var localDurationErrorDescription: String?
    }

    nonisolated struct DocumentOutcome<Document: Sendable>: Sendable {
        var document: Document?
        var documentErrorDescription: String?
        var fileInfo: EpisodeDiagnosticsFileInfo?
    }

    private func enrichDownload(fileURL: URL?, storedSHA256: String?) async -> DownloadEnrichment? {
        guard let fileURL else {
            return nil
        }
        var enrichment = DownloadEnrichment()
        let fileInfo = await dependencies.fileInspector.fileInfo(at: fileURL)
        enrichment.fileInfo = fileInfo
        guard fileInfo.exists else {
            return enrichment
        }
        do {
            enrichment.localDuration = try await dependencies.fileInspector.audioDuration(at: fileURL)
        } catch is CancellationError {
            return enrichment
        } catch {
            enrichment.localDurationErrorDescription = error.localizedDescription
        }
        // Hashing streams the whole episode from disk; with no recorded hash
        // there is nothing to compare against, so a plain sheet open skips it.
        guard storedSHA256?.isEmpty == false else {
            return enrichment
        }
        do {
            enrichment.computedSHA256 = try await dependencies.fileInspector.sha256(at: fileURL)
        } catch is CancellationError {
            return enrichment
        } catch {
            enrichment.sha256ErrorDescription = error.localizedDescription
        }
        return enrichment
    }

    private func loadTranscriptDocument(
        appModel: OpenCastAppModel,
        hasRecord: Bool,
        fileURL: URL?
    ) async -> DocumentOutcome<EpisodeTranscriptDocument> {
        var outcome = DocumentOutcome<EpisodeTranscriptDocument>()
        guard hasRecord else {
            return outcome
        }
        if let fileURL {
            outcome.fileInfo = await dependencies.fileInspector.fileInfo(at: fileURL)
        }
        do {
            outcome.document = try await appModel.transcriptions.loadDocument(for: episodeID)
        } catch {
            outcome.documentErrorDescription = error.localizedDescription
        }
        return outcome
    }

    private func loadAdDocument(
        appModel: OpenCastAppModel,
        hasRecord: Bool,
        fileURL: URL?
    ) async -> DocumentOutcome<EpisodeAdAnalysisDocument> {
        var outcome = DocumentOutcome<EpisodeAdAnalysisDocument>()
        guard hasRecord else {
            return outcome
        }
        if let fileURL {
            outcome.fileInfo = await dependencies.fileInspector.fileInfo(at: fileURL)
        }
        do {
            outcome.document = try await appModel.adAnalyses.loadDocument(for: episodeID)
        } catch {
            outcome.documentErrorDescription = error.localizedDescription
        }
        return outcome
    }

    private func probeSection(urlString: String?, footnote: String?) async -> EpisodeDiagnosticsSection {
        guard let urlString, let url = URL(string: urlString) else {
            return EpisodeDiagnosticsSection(rows: [("Status", "No URL to probe.")], footnote: footnote)
        }
        let probe = await dependencies.networkProber.headProbe(of: url)
        return Self.probeSection(probe: probe, footnote: footnote)
    }

    private func transcriptDuration(
        record: EpisodeTranscriptRecord?,
        document: EpisodeTranscriptDocument?
    ) -> TimeInterval? {
        if let duration = document?.audioDuration, duration > 0 {
            return duration
        }
        if let duration = record?.audioDuration, duration > 0 {
            return duration
        }
        return nil
    }

    private func setSection(_ id: EpisodeDiagnosticsSectionID, _ state: EpisodeDiagnosticsSectionState) {
        sectionStates[id] = state
        reportRevision += 1
    }
}
