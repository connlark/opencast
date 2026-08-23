import SwiftUI

struct SheetDestinationView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let destination: SheetDestination
    let onDismiss: () -> Void

    var body: some View {
        switch destination {
        case .addPodcast:
            AddPodcastView(
                directoryService: appModel.podcastDirectoryService,
                directoryResolver: appModel.podcastDirectoryResolver
            )
        case .episodeInfo(let episodeID):
            EpisodeInfoSheet(episodeID: episodeID)
        case .importOPMLFile(let url):
            OPMLFileImportView(url: url)
        case .nukeConfirmation:
            NukeConfirmationSheet()
        case .onboarding:
            OnboardingView(
                directoryService: appModel.podcastDirectoryService,
                directoryResolver: appModel.podcastDirectoryResolver,
                onCompleted: onDismiss
            )
        case .podcastPlaybackSettings(let feedURL):
            PodcastPlaybackSettingsView(feedURL: feedURL)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}
