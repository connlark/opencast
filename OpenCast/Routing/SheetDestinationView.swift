import SwiftUI

struct SheetDestinationView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let destination: SheetDestination
    let onDismiss: () -> Void
    var onChooseOrganizerShow: (String) -> Void = { _ in }

    var body: some View {
        switch destination {
        case .addPodcast:
            AddPodcastView(
                directoryService: appModel.podcastDirectoryService,
                directoryResolver: appModel.podcastDirectoryResolver
            )
        case .addToPlaylist(let episodeID):
            AddToPlaylistSheet(episodeID: episodeID)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
        case .playlistOrganizer(let podcastID):
            PlaylistOrganizerSheet(podcastID: podcastID)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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
        case .upNext:
            UpNextQueueView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        case .playlistOrganizerShowPicker:
            PlaylistOrganizerShowPickerSheet(onChoose: onChooseOrganizerShow)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}
