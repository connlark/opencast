import OpenCastCore
import SwiftData
import SwiftUI

/// The playing episode's show notes as the episode page renders them
/// (`EpisodeShowNotesView`), resolved the same way: the cached detail's notes,
/// else the summary. A timestamp link seeks the playing episode.
struct NowPlayingShowNotesPaneView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var content: EpisodeShowNotesContent?
    @State private var playbackErrorMessage: String?

    let episode: Episode

    var body: some View {
        Group {
            if let content {
                if content.isEmpty {
                    ContentUnavailableView("No Show Notes", systemImage: NowPlayingSecondaryPane.showNotes.systemImage)
                } else {
                    ScrollView {
                        EpisodeShowNotesView(blocks: content.blocks, onSelectTimestamp: seek)
                            .padding()
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: episode.id) {
            await loadContent()
        }
        .alert("Couldn’t Play", item: $playbackErrorMessage) { _ in
        } message: { message in
            Text(message)
        }
    }

    private func loadContent() async {
        content = nil
        let detail = await appModel.library.episodeDetail(for: episode.id.rawValue)
        guard !Task.isCancelled else {
            return
        }
        let resolved = await EpisodeShowNotesContent.resolving(
            episodeID: episode.id.rawValue,
            summaryHTML: detail?.listItem.summary ?? episode.summary,
            showNotesHTML: detail?.showNotesHTML ?? episode.showNotesHTML,
            duration: episode.duration
        )
        guard !Task.isCancelled else {
            return
        }
        content = resolved
    }

    private func seek(to seconds: TimeInterval) {
        do {
            try EpisodeTimestampPlayback.seek(
                to: seconds,
                episode: EpisodeListItemSnapshot(episode: episode),
                appModel: appModel,
                modelContext: modelContext
            )
        } catch {
            playbackErrorMessage = error.localizedDescription
        }
    }
}
