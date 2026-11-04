import SwiftData
import SwiftUI

/// The queue as the sheet and the Now Playing pane show it: its own stack
/// around `UpNextQueueContent`, a row plays its episode, and the sheet
/// closes after it does.
struct UpNextQueueView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var activeAlert: UpNextQueueAlert?

    var host: NowPlayingSecondaryHost = .sheet

    var body: some View {
        NavigationStack {
            UpNextQueueContent(activeAlert: $activeAlert, onSelectEpisode: play)
        }
        .alert(
            activeAlert?.title ?? "Up Next Error",
            item: $activeAlert
        ) { _ in
        } message: { alert in
            Text(alert.message)
        }
    }

    private func play(_ episode: EpisodeListItemSnapshot) {
        do {
            try appModel.playEpisode(
                episode,
                presentsNowPlaying: false,
                modelContext: modelContext
            )
            if host.dismissesAfterSelection {
                dismiss()
            }
        } catch {
            activeAlert = .playback(error.localizedDescription)
        }
    }
}
