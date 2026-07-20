import SwiftUI

struct EpisodeLocalStatusBadgesView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let episodeID: String

    var body: some View {
        HStack(spacing: 5) {
            if appModel.downloads.record(for: episodeID)?.state == .completed {
                Label("Downloaded", systemImage: "arrow.down.circle.fill")
                    .labelStyle(.iconOnly)
            }

            if appModel.transcriptions.record(for: episodeID)?.state == .completed {
                Label("Transcript available", systemImage: "text.quote")
                    .labelStyle(.iconOnly)
            }
        }
    }
}
