import AppIntents
import CoreSpotlight

@AppEntity(schema: .audio.podcastShow)
struct OpenCastPodcastEntity: IndexedEntity {
    static let defaultQuery = OpenCastPodcastQuery()
    let id: String
    @Property(indexingKey: \.title) var title: String
    var showDescription: String?

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .audio)
        attributes.title = title
        return attributes
    }

    init(id: String, title: String) {
        self.id = id
        self.title = String(title.prefix(512))
        showDescription = nil
    }
}
