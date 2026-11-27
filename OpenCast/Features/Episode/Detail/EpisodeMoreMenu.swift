import SwiftData
import SwiftUI

struct EpisodeMoreMenu: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(AnalysisKeyNoticeGate.self) private var noticeGate: AnalysisKeyNoticeGate?

    @State private var noteDraft: EpisodeNoteDraft?
    @State private var noteErrorMessage: String?

    let episode: EpisodeListItemSnapshot
    let isPlayed: Bool
    let isArchived: Bool
    /// False for an archive-only progress row, which leaves through Unarchive instead.
    let offersClearProgress: Bool
    let onClearProgress: () -> Void
    let onDetectAdsAgain: () -> Void
    let onShowEpisodeDiagnostics: () -> Void
    let onActionError: (String) -> Void

    var body: some View {
        Menu {
            Section {
                EpisodeShareMenu(episode: episode)
            }
            Section {
                EpisodeUpNextMenuButtons(
                    state: appModel.upNextMenuState(for: episode),
                    onPlayNext: enqueueNext,
                    onPlayLast: enqueueLast
                )
            }
            progressActions
            Button("Add to Playlist…", systemImage: "music.note.list", action: addToPlaylist)
            Button("Add Episode Note", systemImage: "square.and.pencil", action: addEpisodeNote)
                .accessibilityIdentifier("Add Whole Episode Note")
            Divider()
            downloadActions
            transcriptActions
            adAnalysisActions
            Divider()
            Button("Episode Diagnostics", systemImage: "stethoscope", action: onShowEpisodeDiagnostics)
        } label: {
            Label("Episode Actions", systemImage: "ellipsis.circle")
        }
        .sheet(item: $noteDraft) { draft in
            AddEpisodeNoteSheet(draft: draft)
        }
        .alert("Couldn’t Open Episode Note", item: $noteErrorMessage) { _ in
        } message: { message in
            Text(message)
        }
    }

    private func addEpisodeNote() {
        do {
            let existing = try EpisodeNoteStore.wholeEpisodeNote(for: episode.episodeID, in: modelContext)
            noteDraft = .wholeEpisode(episode: episode, existing: existing)
        } catch {
            noteErrorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var progressActions: some View {
        if !isPlayed {
            Button("Mark Played", systemImage: "checkmark.circle", action: markPlayed)
        }
        EpisodeArchiveButton(episode: episode, isArchived: isArchived)
        if offersClearProgress {
            Button("Clear Progress", systemImage: "arrow.counterclockwise", role: .destructive, action: onClearProgress)
        }
    }

    @ViewBuilder
    private var downloadActions: some View {
        switch appModel.downloadMenuState(for: episode) {
        case .available:
            Button("Download", systemImage: "arrow.down.circle", action: download)
        case .downloading:
            Button("Cancel Download", systemImage: "xmark.circle", action: cancelDownload)
        case .downloaded:
            Button("Delete Download", systemImage: "trash", role: .destructive, action: deleteDownload)
        }
    }

    @ViewBuilder
    private var transcriptActions: some View {
        let downloadRecord = appModel.downloads.record(for: episode.episodeID)
        switch appModel.transcriptions.jobState(
            for: episode.episodeID,
            downloadRecord: downloadRecord,
            modelState: appModel.transcriptionModels.state,
            requiresInstalledWhisperModel: !appModel.appleSpeechAssets.isTranscriberAvailable
        ) {
        case .unavailable, .downloadRequired, .modelBusy:
            EmptyView()
        case .modelRequired:
            Button("Install Speech Model", systemImage: "waveform", action: installSpeechModel)
        case .ready:
            Button("Generate Transcript", systemImage: "text.quote", action: generateTranscript)
        case .running:
            Button("Cancel Transcription", systemImage: "xmark.circle", action: cancelTranscript)
        case .completed:
            if downloadRecord?.state == .completed {
                Button("Regenerate Transcript", systemImage: "arrow.clockwise", action: generateTranscript)
            }
            Button("Delete Transcript", systemImage: "trash", role: .destructive, action: deleteTranscript)
        case .failed, .cancelled:
            Button("Retry Transcription", systemImage: "arrow.clockwise", action: generateTranscript)
            Button("Delete Partial Transcript", systemImage: "trash", role: .destructive, action: deleteTranscript)
        case .interrupted(let record):
            if record.isAppleSpeechTranscript {
                Button("Retry Transcription", systemImage: "arrow.clockwise", action: generateTranscript)
            } else {
                Button("Resume Transcription", systemImage: "play.circle", action: generateTranscript)
            }
            Button("Delete Partial Transcript", systemImage: "trash", role: .destructive, action: deleteTranscript)
        }

        remoteTranscriptActions
    }

    @ViewBuilder
    private var remoteTranscriptActions: some View {
        if appModel.remoteTranscriptionPurchases.isSurfaceVisible {
            if let phase = appModel.remoteTranscription.store.phase(for: episode.episodeID),
               !phase.isTerminal {
                Label("Remote: \(phase.displayText)", systemImage: "cloud")
                if phase.isParked {
                    Button("Resume Remote Transcription", systemImage: "play.circle", action: resumeRemoteTranscript)
                }
                Button("Cancel Remote Transcription", systemImage: "xmark.circle", action: cancelRemoteTranscript)
            } else if RemoteTranscriptionStatusPresentation.make(
                phase: appModel.remoteTranscription.store.phase(for: episode.episodeID)
            )?.offersRetry == true {
                // Resume, so the same reference re-runs where one is kept.
                Button("Retry Remote Transcription", systemImage: "arrow.clockwise", action: resumeRemoteTranscript)
            } else {
                // Disabled while a cloud detect pass owns this episode — it
                // already delivers the transcript when it lands.
                Button("Transcribe Remotely", systemImage: "cloud", action: requestRemoteTranscript)
                    .disabled(appModel.adFreePass.hasActiveOrQueuedCloudItem(for: episode.episodeID))
            }
        }
    }

    @ViewBuilder
    private var adAnalysisActions: some View {
        let detectAdsState = appModel.detectAdsMenuState(for: episode)
        if detectAdsState.offersDetectAgain {
            Button(detectAdsState.title, systemImage: "megaphone", action: onDetectAdsAgain)
        }
        if appModel.transcriptions.record(for: episode.episodeID)?.state == .completed {
            Button("Detect Ads Only", systemImage: "megaphone", action: detectAdsOnly)
                .disabled(!detectAdsState.enablesAnalysisOnly)
        }
        if appModel.adAnalyses.record(for: episode.episodeID) != nil {
            Button("Delete Ad Analysis", systemImage: "trash", role: .destructive, action: deleteAdAnalysis)
        }
    }

    private func enqueueNext() {
        appModel.enqueueInUpNext(episode, at: .next, modelContext: modelContext)
    }

    private func enqueueLast() {
        appModel.enqueueInUpNext(episode, at: .last, modelContext: modelContext)
    }

    private func markPlayed() {
        appModel.markEpisodePlayed(episode, modelContext: modelContext)
    }

    private func addToPlaylist() {
        appModel.requestAddToPlaylist(episodeID: episode.episodeID)
    }

    private func download() {
        appModel.downloads.startDownload(for: episode, modelContext: modelContext)
    }

    private func cancelDownload() {
        appModel.downloads.cancelDownload(episodeID: episode.episodeID, modelContext: modelContext)
    }

    private func deleteDownload() {
        guard let record = appModel.downloads.record(for: episode.episodeID) else {
            return
        }
        appModel.deleteDownload(record, modelContext: modelContext)
    }

    private func installSpeechModel() {
        appModel.installTranscriptionModel()
    }

    private func generateTranscript() {
        guard let downloadRecord = appModel.downloads.record(for: episode.episodeID) else {
            return
        }
        appModel.transcribeDownloadedEpisode(episode, downloadRecord: downloadRecord, modelContext: modelContext)
    }

    private func cancelTranscript() {
        appModel.cancelEpisodeTranscription(episodeID: episode.episodeID, modelContext: modelContext)
    }

    private func requestRemoteTranscript() {
        appModel.remoteTranscription.store.startPreview = RemoteTranscriptionStartPreviewRequest(
            episodeID: episode.episodeID,
            durationSeconds: episode.duration
        )
    }

    private func resumeRemoteTranscript() {
        switch appModel.resumeRemoteTranscription(episode: episode, modelContext: modelContext) {
        case .started:
            break
        case .rejected(let message):
            onActionError(message)
        }
    }

    private func cancelRemoteTranscript() {
        appModel.remoteTranscription.cancel()
    }

    private func deleteTranscript() {
        appModel.deleteEpisodeTranscript(episodeID: episode.episodeID, modelContext: modelContext)
    }

    private func detectAdsOnly() {
        guard let noticeGate else {
            analyzeTranscript()
            return
        }
        noticeGate.run(appModel: appModel, analyzeTranscript)
    }

    private func analyzeTranscript() {
        Task {
            let document: EpisodeTranscriptDocument
            do {
                document = try await appModel.transcriptions.loadDocument(for: episode.episodeID)
            } catch is CancellationError {
                return
            } catch {
                onActionError(error.localizedDescription)
                return
            }
            appModel.analyzeEpisodeTranscript(document, modelContext: modelContext)
        }
    }

    private func deleteAdAnalysis() {
        appModel.deleteEpisodeAdAnalysis(episodeID: episode.episodeID, modelContext: modelContext)
    }
}

#Preview("Dark") {
    NavigationStack {
        Text("Episode")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    EpisodeMoreMenu(
                        episode: .previewSample,
                        isPlayed: false,
                        isArchived: false,
                        offersClearProgress: true,
                        onClearProgress: {},
                        onDetectAdsAgain: {},
                        onShowEpisodeDiagnostics: {},
                        onActionError: { _ in }
                    )
                }
            }
    }
    .environment(OpenCastAppModel())
    .preferredColorScheme(.dark)
}

#Preview("Light") {
    NavigationStack {
        Text("Episode")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    EpisodeMoreMenu(
                        episode: .previewSample,
                        isPlayed: false,
                        isArchived: true,
                        offersClearProgress: false,
                        onClearProgress: {},
                        onDetectAdsAgain: {},
                        onShowEpisodeDiagnostics: {},
                        onActionError: { _ in }
                    )
                }
            }
    }
    .environment(OpenCastAppModel())
    .preferredColorScheme(.light)
}
