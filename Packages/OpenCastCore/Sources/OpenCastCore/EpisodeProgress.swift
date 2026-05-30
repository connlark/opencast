import Foundation

public struct EpisodeProgress: Codable, Hashable, Sendable {
    public var episodeID: EpisodeID
    public var position: TimeInterval
    public var duration: TimeInterval?
    public var isPlayed: Bool
    public var updatedAt: Date

    public init(
        episodeID: EpisodeID,
        position: TimeInterval = 0,
        duration: TimeInterval? = nil,
        isPlayed: Bool = false,
        updatedAt: Date = .now
    ) {
        self.episodeID = episodeID
        self.position = position
        self.duration = duration
        self.isPlayed = isPlayed
        self.updatedAt = updatedAt
    }
}
