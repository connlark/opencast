import Foundation

public struct Episode: Codable, Hashable, Identifiable, Sendable {
    public var id: EpisodeID
    public var podcastID: PodcastID
    public var podcastTitle: String
    public var title: String
    public var summary: String?
    public var showNotesHTML: String?
    public var publishedAt: Date?
    public var duration: TimeInterval?
    public var audioURL: URL?
    public var artworkURL: URL?
    public var guid: String?

    public init(
        id: EpisodeID,
        podcastID: PodcastID,
        podcastTitle: String,
        title: String,
        summary: String? = nil,
        showNotesHTML: String? = nil,
        publishedAt: Date? = nil,
        duration: TimeInterval? = nil,
        audioURL: URL? = nil,
        artworkURL: URL? = nil,
        guid: String? = nil
    ) {
        self.id = id
        self.podcastID = podcastID
        self.podcastTitle = podcastTitle
        self.title = title
        self.summary = summary
        self.showNotesHTML = showNotesHTML
        self.publishedAt = publishedAt
        self.duration = duration
        self.audioURL = audioURL
        self.artworkURL = artworkURL
        self.guid = guid
    }
}
