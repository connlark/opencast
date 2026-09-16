import Foundation

enum SheetDestination: Identifiable {
    case addPodcast
    case episodeDiagnostics(episodeID: String)
    case helpTopic(id: String)
    case importOPMLFile(URL)
    case nukeConfirmation
    case onboarding
    case podcastPlaybackSettings(feedURL: String)
    case transcriptRecap(episodeID: String, kind: TranscriptRecapWindowKind, playhead: TimeInterval)
    case transcriptAsk(episodeID: String)

    var id: String {
        switch self {
        case .addPodcast:
            "addPodcast"
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
        case .podcastPlaybackSettings(let feedURL):
            "podcastPlaybackSettings-\(feedURL)"
        case .transcriptRecap(let episodeID, let kind, let playhead):
            "transcriptRecap-\(episodeID)-\(kind.rawValue)-\(Int(playhead))"
        case .transcriptAsk(let episodeID):
            "transcriptAsk-\(episodeID)"
        }
    }
}
