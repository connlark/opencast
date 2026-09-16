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
        case .episodeDiagnostics(let episodeID):
            EpisodeDiagnosticsSheet(episodeID: episodeID)
        case .helpTopic(let id):
            HelpTopicSheet(topicID: id)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
        case .transcriptRecap(let episodeID, let kind, let playhead):
            TranscriptRecapSheet(episodeID: episodeID, kind: kind, playhead: playhead)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        case .transcriptAsk(let episodeID):
            TranscriptAskSheet(episodeID: episodeID)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}
