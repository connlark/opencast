import OpenCastTranscription
import SwiftData
import SwiftUI

struct EpisodeTranscriptView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("transcript.showsTimestamps") private var showsTimestamps = false

    let episodeID: String

    @State private var document: EpisodeTranscriptDocument?
    @State private var transcriptLoadRevision = 0
    @State private var adAnalysisDocument: EpisodeAdAnalysisDocument?
    @State private var adSpanBySegmentID: [Int: TranscriptAdHighlight] = [:]
    @State private var adAnalysisJobState: EpisodeAdAnalysisJobState = .unavailable("Transcript unavailable.")
    @State private var plainTextExport = ""
    @State private var timestampedTextExport = ""
    @State private var isLoadingDocument = true
    @State private var loadErrorMessage: String?
    @State private var timeline = TranscriptTimeline()
    @State private var searchIndex: TranscriptSearchIndex?
    @State private var isSearchPresented = false
    @State private var recapMenuState = TranscriptRecapMenuState()
    @State private var sheetDestination: SheetDestination?

    var body: some View {
        Group {
            if isLoadingDocument {
                ProgressView("Loading Transcript")
            } else if let document {
                EpisodeTranscriptContentView(
                    episodeID: episodeID,
                    document: document,
                    timeline: timeline,
                    searchIndex: searchIndex,
                    adSpanBySegmentID: adSpanBySegmentID,
                    adAnalysisState: adAnalysisJobState,
                    showsTimestamps: showsTimestamps,
                    isSearchPresented: $isSearchPresented
                )
            } else {
                ContentUnavailableView {
                    Label("Transcript Missing", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text(loadErrorMessage ?? "The transcript file could not be found.")
                }
            }
        }
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let document {
                ToolbarItem(placement: .primaryAction) {
                    Button("Search Transcript", systemImage: "magnifyingglass", action: toggleSearch)
                }
                ToolbarItem(placement: .primaryAction) {
                    EpisodeTranscriptMenu(
                        showsTimestamps: $showsTimestamps,
                        plainTextExport: plainTextExport,
                        timestampedTextExport: timestampedTextExport,
                        adAnalysisState: adAnalysisJobState,
                        canAnalyze: appModel.adAnalyses.canStartAnalysis,
                        canImproveTranscript: canImproveTranscript(for: document),
                        recapMenuState: appModel.transcriptIntelligence.isVisible ? recapMenuState : nil,
                        showsAsk: appModel.transcriptIntelligence.isAskVisible,
                        onRecap: presentRecap,
                        onAsk: presentAsk,
                        onAnalyzeAds: analyzeAds,
                        onDeleteAdAnalysis: deleteAdAnalysis,
                        onImproveTranscript: improveTranscript,
                        onDeleteTranscript: deleteTranscript
                    )
                }
            }
        }
        .task(id: transcriptDocumentLoadIdentifier) {
            await loadDocument()
        }
        .task(id: adAnalysisDocumentLoadIdentifier) {
            await loadAdAnalysisDocumentIfAvailable()
        }
        .task(id: adAnalysisStateIdentifier) {
            refreshAdAnalysisDerivedState()
        }
        .task(id: recapMenuStateIdentifier) {
            refreshRecapMenuState()
        }
        .background {
            // Zero-sized: only this child re-evaluates on the 1 Hz tick;
            // the menu re-renders when a recap threshold is crossed.
            TranscriptPlaybackObserver(
                onPositionTick: refreshRecapMenuState,
                onStateChange: refreshRecapMenuState,
                onProgressBoundary: refreshRecapMenuState
            )
        }
        .sheet(item: $sheetDestination) { destination in
            SheetDestinationView(destination: destination, onDismiss: dismissSheet)
        }
    }

    // MARK: - Derived state

    private var adAnalysisDocumentLoadIdentifier: String {
        let updatedAt = appModel.adAnalyses.record(for: episodeID)?.updatedAt.timeIntervalSince1970 ?? -1
        // The two document tasks start independently. Wait for the actual
        // transcript and re-resolve when a replacement finishes loading, even
        // if the saved analysis record itself has not changed.
        return "\(episodeID)|\(updatedAt)|\(transcriptLoadRevision)"
    }

    /// The cached job state feeds both the content view and the menu; it
    /// recomputes (one fingerprint pass) only when a job or transcript state
    /// actually changes, never per body evaluation.
    private var adAnalysisStateIdentifier: String {
        let transcriptState = appModel.transcriptions.record(for: episodeID)?.state.rawValue ?? "missing"
        return "\(episodeID)|\(transcriptState)|\(appModel.adAnalyses.changeSequence)"
    }

    /// Reloads only when a completed transcript lands (initial open or an
    /// "Improve Transcript" regeneration finishing) — checkpoint writes during
    /// a run keep the stamp at -1 so the old document stays on screen.
    private var transcriptDocumentLoadIdentifier: String {
        let record = appModel.transcriptions.record(for: episodeID)
        let completedStamp = record?.state == .completed
            ? record?.updatedAt.timeIntervalSince1970 ?? -1
            : -1
        return "\(episodeID)|\(completedStamp)"
    }

    /// Reloads the menu state when the document, eligibility, or the current
    /// episode changes; playhead movement arrives through the observer.
    private var recapMenuStateIdentifier: String {
        "\(transcriptLoadRevision)|\(appModel.transcriptIntelligence.isVisible)|\(appModel.playback.currentEpisode?.id.rawValue ?? "none")"
    }

    private func canImproveTranscript(for document: EpisodeTranscriptDocument) -> Bool {
        guard document.modelIdentifier.hasPrefix("openai_whisper"),
              appModel.appleSpeechAssets.isTranscriberAvailable,
              appModel.transcriptions.record(for: episodeID)?.state == .completed,
              !appModel.transcriptions.hasActiveJob,
              appModel.transcriptImprovement.phase == .idle,
              let downloadRecord = appModel.downloads.record(for: episodeID),
              downloadRecord.state == .completed,
              appModel.downloads.downloadedFileExists(for: downloadRecord)
        else {
            return false
        }
        return true
    }

    private func adAnalysisState(for document: EpisodeTranscriptDocument) -> EpisodeAdAnalysisJobState {
        appModel.adAnalyses.jobState(
            for: document,
            transcriptState: appModel.transcriptions.record(for: episodeID)?.state
        )
    }

    // MARK: - Search

    private func toggleSearch() {
        isSearchPresented.toggle()
    }

    // MARK: - Recap

    /// The playback controller's position while this episode is current;
    /// the saved progress otherwise. Read in actions, never in body, so the
    /// toolbar owner does not subscribe to the 1 Hz tick.
    private func recapPlayhead() -> TimeInterval {
        if appModel.playback.currentEpisode?.id.rawValue == episodeID {
            return appModel.playback.position
        }
        return appModel.library.progressRecord(for: episodeID)?.position ?? 0
    }

    private func refreshRecapMenuState() {
        guard document != nil, appModel.transcriptIntelligence.isVisible else {
            return
        }
        let state = TranscriptRecapMenuState.resolve(playhead: recapPlayhead())
        if state != recapMenuState {
            recapMenuState = state
        }
    }

    private func presentRecap(_ kind: TranscriptRecapWindowKind) {
        sheetDestination = .transcriptRecap(episodeID: episodeID, kind: kind, playhead: recapPlayhead())
    }

    private func presentAsk() {
        sheetDestination = .transcriptAsk(episodeID: episodeID)
    }

    private func dismissSheet() {
        sheetDestination = nil
    }

    // MARK: - Document loading

    private func loadDocument() async {
        if document == nil {
            isLoadingDocument = true
        }
        loadErrorMessage = nil
        do {
            let loaded = try await appModel.transcriptions.loadDocument(for: episodeID)
            let segments = loaded.segments
            let index = try await TranscriptSearchIndex.build(segments: segments)
            let exports = await Self.buildExports(segments: segments)
            try Task.checkCancellation()
            document = loaded
            transcriptLoadRevision += 1
            adAnalysisDocument = nil
            timeline = TranscriptTimeline(segments: segments)
            searchIndex = index
            plainTextExport = exports.plain
            timestampedTextExport = exports.timestamped
            isLoadingDocument = false
            refreshAdAnalysisDerivedState()
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            // A running improve points the record at its in-progress
            // replacement document; keep the current transcript on screen
            // until a completed one lands.
            guard appModel.transcriptions.record(for: episodeID)?.state != .running else {
                isLoadingDocument = false
                return
            }
            document = nil
            transcriptLoadRevision += 1
            adAnalysisDocument = nil
            adSpanBySegmentID = [:]
            plainTextExport = ""
            timestampedTextExport = ""
            timeline = TranscriptTimeline()
            searchIndex = nil
            loadErrorMessage = error.localizedDescription
            isLoadingDocument = false
            refreshAdAnalysisDerivedState()
        }
    }

    private func loadAdAnalysisDocumentIfAvailable() async {
        guard let document,
              appModel.adAnalyses.record(for: episodeID)?.state == .completed
        else {
            adAnalysisDocument = nil
            adSpanBySegmentID = [:]
            return
        }

        let loadIdentifier = adAnalysisDocumentLoadIdentifier
        do {
            let loaded = try await appModel.adAnalyses.loadDocument(for: episodeID, transcript: document)
            // File I/O/refinement can finish after this task was replaced.
            // Never let an obsolete transcript's cuts overwrite the new ones.
            try Task.checkCancellation()
            guard loadIdentifier == adAnalysisDocumentLoadIdentifier else { return }
            adAnalysisDocument = loaded
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, loadIdentifier == adAnalysisDocumentLoadIdentifier else { return }
            adAnalysisDocument = nil
        }
        refreshAdAnalysisDerivedState()
    }

    /// One jobState computation feeds the content view, the menu, and the
    /// span lookup (perf 25's double-tax collapsed to a single pass).
    private func refreshAdAnalysisDerivedState() {
        guard let document else {
            adAnalysisJobState = .unavailable("Transcript unavailable.")
            adSpanBySegmentID = [:]
            return
        }
        let state = adAnalysisState(for: document)
        adAnalysisJobState = state
        adSpanBySegmentID = adSpanLookup(
            for: document,
            currentAdAnalysisDocument: loadedCurrentAdAnalysisDocument(
                for: document,
                state: state
            )
        )
    }

    @concurrent
    private static func buildExports(
        segments: [OpenCastTranscriptSegment]
    ) async -> (plain: String, timestamped: String) {
        (
            TranscriptExportBuilder.plainText(from: segments),
            TranscriptExportBuilder.timestampedText(from: segments)
        )
    }

    private func loadedCurrentAdAnalysisDocument(
        for transcriptDocument: EpisodeTranscriptDocument,
        state: EpisodeAdAnalysisJobState
    ) -> EpisodeAdAnalysisDocument? {
        guard case .completed(_, isStale: false) = state else {
            return nil
        }
        guard let adAnalysisDocument,
              appModel.adAnalyses.isCurrentAnalysisDocument(adAnalysisDocument, for: transcriptDocument)
        else {
            return nil
        }
        return adAnalysisDocument
    }

    private func adSpanLookup(
        for transcriptDocument: EpisodeTranscriptDocument,
        currentAdAnalysisDocument: EpisodeAdAnalysisDocument?
    ) -> [Int: TranscriptAdHighlight] {
        guard let currentAdAnalysisDocument else {
            return [:]
        }

        var lookup: [Int: TranscriptAdHighlight] = [:]
        for segment in transcriptDocument.segments {
            lookup[segment.id] = TranscriptAdHighlight(spans: currentAdAnalysisDocument.spans, segment: segment)
        }
        return lookup
    }

    // MARK: - Transcript actions

    private func deleteTranscript() {
        appModel.deleteEpisodeTranscript(episodeID: episodeID, modelContext: modelContext)
        document = nil
        adAnalysisDocument = nil
        adSpanBySegmentID = [:]
        plainTextExport = ""
        timestampedTextExport = ""
        timeline = TranscriptTimeline()
        searchIndex = nil
        loadErrorMessage = nil
        dismiss()
    }

    private func analyzeAds() {
        guard let document else {
            return
        }
        appModel.analyzeEpisodeTranscript(document, modelContext: modelContext)
        refreshAdAnalysisDerivedState()
    }

    private func improveTranscript() {
        appModel.improveTranscriptWithAppleSpeech(episodeID: episodeID, modelContext: modelContext)
        refreshAdAnalysisDerivedState()
    }

    // Mutating actions refresh the derived state synchronously: deleting the
    // record destroys the very model object whose property reads back the
    // task-id observation, so nothing else would invalidate this body. The
    // task id still covers background transitions (poll completion mutates a
    // live record's updatedAt, which body observes via the load identifiers).
    private func deleteAdAnalysis() {
        appModel.deleteEpisodeAdAnalysis(episodeID: episodeID, modelContext: modelContext)
        adAnalysisDocument = nil
        adSpanBySegmentID = [:]
        refreshAdAnalysisDerivedState()
    }
}
