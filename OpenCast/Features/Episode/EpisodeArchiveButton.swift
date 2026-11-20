import SwiftData
import SwiftUI

/// Each button performs only the command it names, never a toggle: if the state changes between
/// drawing and tapping, the tap is a no-op rather than the opposite command.
struct EpisodeArchiveButton: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let episode: EpisodeListItemSnapshot
    let isArchived: Bool

    var body: some View {
        if isArchived {
            Button("Unarchive", systemImage: "tray.and.arrow.up", action: unarchive)
        } else {
            Button("Archive", systemImage: "archivebox", action: archive)
        }
    }

    private func archive() {
        appModel.archiveEpisode(episode, modelContext: modelContext)
    }

    private func unarchive() {
        appModel.unarchiveEpisode(episode, modelContext: modelContext)
    }
}
