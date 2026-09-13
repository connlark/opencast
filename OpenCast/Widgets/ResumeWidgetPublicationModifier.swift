import SwiftData
import SwiftUI

struct ResumeWidgetPublicationModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content.task(id: candidate) {
            await appModel.ensurePlaybackSurfaceHydrated(modelContext: modelContext)
            guard !Task.isCancelled, !OpenCastLaunchConfiguration.current.usesInMemoryStore else { return }
            await ResumeWidgetPublisher.shared.publish(candidate)
        }
    }

    private var candidate: ResumeWidgetCandidate? {
        guard let current = appModel.playback.currentEpisode,
              appModel.library.isActivelySubscribed(to: current.podcastID.rawValue),
              let episode = appModel.episodeSnapshot(for: current.id.rawValue)
        else { return nil }
        return ResumeWidgetCandidate(
            episodeID: episode.episodeID, title: String(episode.title.prefix(512)), showTitle: String(episode.podcastTitle.prefix(512)),
            artworkURL: current.artworkURL,
            artworkRevision: appModel.library.artworkPreview(for: episode)?.sourceHash,
            progressBucket: Int(max(0, appModel.playback.position.isFinite ? appModel.playback.position : 0) / 300),
            isPlaying: appModel.playback.state == .playing
        )
    }
}
