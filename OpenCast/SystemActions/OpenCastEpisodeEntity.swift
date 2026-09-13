import AppIntents
import CoreSpotlight
import Foundation

@AppEntity(schema: .audio.podcastEpisode)
struct OpenCastEpisodeEntity: IndexedEntity {
    static let defaultQuery = OpenCastEpisodeQuery()
    let id: String
    @Property(indexingKey: \.title) var title: String
    var showName: String?
    var show: OpenCastPodcastEntity?
    var releaseDate: Date?
    var duration: Double?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(showName ?? "")")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .audio)
        attributes.title = title
        attributes.artist = showName
        attributes.contentCreationDate = releaseDate
        return attributes
    }

    init(episode: EpisodeListItemSnapshot, show: OpenCastPodcastEntity) {
        id = episode.episodeID
        title = String(episode.title.prefix(512))
        showName = show.title
        self.show = show
        releaseDate = episode.publishedAt
        duration = episode.duration
    }
}
