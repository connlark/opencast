import Foundation

enum SheetDestination: Identifiable {
    case addPodcast
    case addToPlaylist(episodeID: String)
    case episodeDiagnostics(episodeID: String)
    case helpTopic(id: String)
    case importOPMLFile(URL)
    case nukeConfirmation
    case onboarding
    case playlistOrganizer(podcastID: String)
    case podcastPlaybackSettings(feedURL: String)
    case transcriptRecap(episodeID: String, kind: TranscriptRecapWindowKind, playhead: TimeInterval)
    case transcriptAsk(episodeID: String)
    case upNext
    /// Presented only by `PlaylistsView`. A presenter must pass
    /// `onChooseOrganizerShow` to `SheetDestinationView`; its default no-op
    /// would leave the picker's rows silently inert.
    case playlistOrganizerShowPicker

    var id: String {
        switch self {
        case .addPodcast:
            "addPodcast"
        case .addToPlaylist(let episodeID):
            "addToPlaylist-\(episodeID)"
        case .episodeDiagnostics(let episodeID):
            "episodeDiagnostics-\(episodeID)"
        case .helpTopic(let id):
            "helpTopic-\(id)"
        case .importOPMLFile(let url):
            "importOPMLFile-\(url.absoluteString)"
        case .nukeConfirmation:
            "nukeConfirmation"
        case .onboarding:
            "onboarding"
        case .playlistOrganizer(let podcastID):
            "playlistOrganizer-\(podcastID)"
        case .podcastPlaybackSettings(let feedURL):
            "podcastPlaybackSettings-\(feedURL)"
        case .transcriptRecap(let episodeID, let kind, let playhead):
            "transcriptRecap-\(episodeID)-\(kind.rawValue)-\(Int(playhead))"
        case .transcriptAsk(let episodeID):
            "transcriptAsk-\(episodeID)"
        case .upNext:
            "upNext"
        case .playlistOrganizerShowPicker:
            "playlistOrganizerShowPicker"
        }
    }
}
