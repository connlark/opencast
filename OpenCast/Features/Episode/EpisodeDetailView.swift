import OpenCastPlayback
import SwiftData
import SwiftUI

struct EpisodeDetailView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let episodeID: String
    @State private var episodeSummaryText: String?
    @State private var showNotesPlainText: String?
    @State private var showNotesShouldRender = false
    @State private var isConfirmingClearProgress = false

    private var episode: EpisodeListItemSnapshot? {
        appModel.library.episode(with: episodeID)
    }

    var body: some View {
        let episode = episode
        let progressSummary = episode.map { appModel.library.progressSummary(for: $0) }
        let progressRecord = episode.flatMap { appModel.library.progressRecord(for: $0.episodeID) }

        Group {
            if let episode {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top, spacing: 16) {
                            ArtworkPlaceholder(
                                title: episode.podcastTitle,
                                imageURL: episode.artworkURL,
                                size: 96,
                                cacheKind: .episode,
                                preview: episode.artworkPreview,
                                onPreviewResolved: updateArtworkPreview
                            )

                            VStack(alignment: .leading, spacing: 8) {
                                Text(episode.title)
                                    .font(.title2)
                                Text(episode.podcastTitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if let publishedAt = episode.publishedAt {
                                    Text(publishedAt, format: .dateTime.month(.wide).day().year())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let progressSummary {
                                    progressStatus(progressSummary)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)

                        Button {
                            play(episode)
                        } label: {
                            Label("Play Episode", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)

                        EpisodeDownloadControlsView(
                            record: appModel.downloads.record(for: episode.episodeID),
                            lastErrorMessage: appModel.downloads.lastErrorMessage(for: episode.episodeID),
                            onDownload: { download(episode) },
                            onCancel: { cancelDownload(episode) },
                            onDelete: { deleteDownload(episode) },
                            onPlayDownloaded: { playDownloaded(episode) }
                        )

                        if let summary = episodeSummaryText {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Summary")
                                    .font(.headline)
                                Text(summary)
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if showNotesShouldRender, let showNotesPlainText {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Show Notes")
                                    .font(.headline)

                                Text(showNotesPlainText)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding()
                    .padding(.bottom, 72)
                }
            } else {
                ContentUnavailableView("Episode Not Found", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle("Episode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let episode, let progressSummary {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if !progressSummary.isCompleted {
                            Button("Mark Played", systemImage: "checkmark.circle") {
                                markPlayed(episode)
                            }
                        }

                        if progressRecord != nil {
                            Button("Clear Progress", systemImage: "arrow.counterclockwise", role: .destructive) {
                                confirmClearProgress()
                            }
                        }
                    } label: {
                        Label("Episode Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear progress for \(episode?.title ?? "this episode")?",
            isPresented: $isConfirmingClearProgress,
            titleVisibility: .visible
        ) {
            Button("Clear Progress", role: .destructive, action: clearProgress)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Listening position for this episode will be removed. Downloads are unchanged.")
        }
        .task(id: TextContentTaskKey(
            episodeID: episode?.episodeID,
            isNowPlayingPresented: appModel.isNowPlayingPresented
        )) {
            let episode = episode
            guard !appModel.isNowPlayingPresented else {
                return
            }

            await updateTextContent(for: episode)
        }
    }

    private func play(_ episode: EpisodeListItemSnapshot) {
        nowPlayingProbeMark("playepisode-tap")
        runPlaybackAction {
            try appModel.playEpisode(episode, modelContext: modelContext)
        }
    }

    private func updateArtworkPreview(_ preview: ArtworkPreview) {
        guard let episode else {
            return
        }

        appModel.library.updateArtworkPreview(preview, for: episode)
    }

    private func markPlayed(_ episode: EpisodeListItemSnapshot) {
        appModel.markEpisodePlayed(episode, modelContext: modelContext)
    }

    private func confirmClearProgress() {
        isConfirmingClearProgress = true
    }

    private func clearProgress() {
        guard let episode else {
            return
        }

        appModel.clearEpisodeProgress(episode, modelContext: modelContext)
    }

    private func runPlaybackAction(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            appModel.lastPlaybackError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func progressStatus(_ progressSummary: EpisodeProgressSummary) -> some View {
        if progressSummary.isCompleted {
            Label("Completed", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if progressSummary.hasVisibleProgress {
            VStack(alignment: .leading, spacing: 5) {
                if progressSummary.duration != nil {
                    EpisodeProgressBarView(fractionCompleted: progressSummary.fractionCompleted)
                        .frame(width: 180)
                }

                Text(progressSummary.remainingText ?? "In progress")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(progressSummary.accessibilityDescription)
        }
    }

    private func playDownloaded(_ episode: EpisodeListItemSnapshot) {
        runPlaybackAction {
            guard let downloadRecord = appModel.downloads.record(for: episode.episodeID) else {
                throw EpisodeDownloadError.missingDownloadedFile
            }

            try appModel.playDownloadedEpisode(
                episode,
                downloadRecord: downloadRecord,
                modelContext: modelContext
            )
        }
    }

    private func download(_ episode: EpisodeListItemSnapshot) {
        appModel.downloads.startDownload(for: episode, modelContext: modelContext)
    }

    private func cancelDownload(_ episode: EpisodeListItemSnapshot) {
        appModel.downloads.cancelDownload(episodeID: episode.episodeID, modelContext: modelContext)
    }

    private func deleteDownload(_ episode: EpisodeListItemSnapshot) {
        guard let downloadRecord = appModel.downloads.record(for: episode.episodeID) else {
            return
        }

        appModel.downloads.deleteDownload(downloadRecord, modelContext: modelContext)
    }

    private func updateTextContent(for episode: EpisodeListItemSnapshot?) async {
        guard let episode else {
            applyTextContent(.empty)
            return
        }

        // Show notes live only in the local cache store; fetch them lazily so
        // list loads never carry them.
        let detail = await appModel.library.episodeDetail(for: episode.episodeID)
        guard !Task.isCancelled else {
            return
        }

        let textContent = await EpisodeTextContent.resolving(
            summaryHTML: episode.summary,
            showNotesHTML: detail?.showNotesHTML
        )
        guard !Task.isCancelled else {
            return
        }

        applyTextContent(textContent)
    }

    private func applyTextContent(_ textContent: EpisodeTextContent) {
        episodeSummaryText = textContent.summary
        showNotesPlainText = textContent.showNotesPlainText
        showNotesShouldRender = textContent.showNotesShouldRender
    }
}

private struct TextContentTaskKey: Equatable {
    let episodeID: String?
    let isNowPlayingPresented: Bool
}
