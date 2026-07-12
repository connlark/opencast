import OpenCastTranscription
import SwiftUI

struct EpisodeTranscriptView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("transcript.showsTimestamps") private var showsTimestamps = false

    let episodeID: String

    @State private var document: EpisodeTranscriptDocument?
    @State private var adAnalysisDocument: EpisodeAdAnalysisDocument?
    @State private var adSpanBySegmentID: [Int: EpisodeAdAnalysisSpan] = [:]
    @State private var isLoadingDocument = true
    @State private var loadErrorMessage: String?
    @State private var timeline = TranscriptTimeline()
    @State private var searchIndex: TranscriptSearchIndex?
    @State private var isSearchPresented = false

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
                    adAnalysisState: adAnalysisState(for: document),
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
                        segments: document.segments,
                        adAnalysisState: adAnalysisState(for: document),
                        canAnalyze: appModel.adAnalyses.canStartAnalysis,
                        canImproveTranscript: canImproveTranscript(for: document),
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
    }

    // MARK: - Derived state

    private var adAnalysisDocumentLoadIdentifier: String {
        let updatedAt = appModel.adAnalyses.record(for: episodeID)?.updatedAt.timeIntervalSince1970 ?? -1
        return "\(episodeID)|\(updatedAt)"
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

    // MARK: - Document loading

    private func loadDocument() async {
        if document == nil {
            isLoadingDocument = true
        }
        loadErrorMessage = nil
        do {
            let loaded = try await appModel.transcriptions.loadDocument(for: episodeID)
            let segments = loaded.segments
            let index = await Task.detached(priority: .userInitiated) {
                TranscriptSearchIndex(segments: segments)
            }.value
            document = loaded
            timeline = TranscriptTimeline(segments: segments)
            searchIndex = index
            isLoadingDocument = false
            refreshAdSpans()
        } catch is CancellationError {
        } catch {
            // A running improve points the record at its in-progress
            // replacement document; keep the current transcript on screen
            // until a completed one lands.
            guard appModel.transcriptions.record(for: episodeID)?.state != .running else {
                isLoadingDocument = false
                return
            }
            document = nil
            adAnalysisDocument = nil
            adSpanBySegmentID = [:]
            timeline = TranscriptTimeline()
            searchIndex = nil
            loadErrorMessage = error.localizedDescription
            isLoadingDocument = false
        }
    }

    private func loadAdAnalysisDocumentIfAvailable() async {
        guard appModel.adAnalyses.record(for: episodeID)?.state == .completed else {
            adAnalysisDocument = nil
            adSpanBySegmentID = [:]
            return
        }

        do {
            adAnalysisDocument = try await appModel.adAnalyses.loadDocument(for: episodeID)
        } catch is CancellationError {
            return
        } catch {
            adAnalysisDocument = nil
        }
        refreshAdSpans()
    }

    private func refreshAdSpans() {
        guard let document else {
            adSpanBySegmentID = [:]
            return
        }
        adSpanBySegmentID = adSpanLookup(
            for: document,
            currentAdAnalysisDocument: loadedCurrentAdAnalysisDocument(
                for: document,
                state: adAnalysisState(for: document)
            )
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
    ) -> [Int: EpisodeAdAnalysisSpan] {
        guard let currentAdAnalysisDocument else {
            return [:]
        }

        let segmentIDs = Set(transcriptDocument.segments.map(\.id))
        var lookup: [Int: EpisodeAdAnalysisSpan] = [:]
        for span in currentAdAnalysisDocument.spans {
            guard span.startSegmentID <= span.endSegmentID else {
                continue
            }
            for segmentID in span.startSegmentID...span.endSegmentID
            where segmentIDs.contains(segmentID) && lookup[segmentID] == nil {
                lookup[segmentID] = span
            }
        }
        return lookup
    }

    // MARK: - Transcript actions

    private func deleteTranscript() {
        appModel.deleteEpisodeTranscript(episodeID: episodeID, modelContext: modelContext)
        document = nil
        adAnalysisDocument = nil
        adSpanBySegmentID = [:]
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
    }

    private func improveTranscript() {
        appModel.improveTranscriptWithAppleSpeech(episodeID: episodeID, modelContext: modelContext)
    }

    private func deleteAdAnalysis() {
        appModel.deleteEpisodeAdAnalysis(episodeID: episodeID, modelContext: modelContext)
        adAnalysisDocument = nil
        adSpanBySegmentID = [:]
    }
}
