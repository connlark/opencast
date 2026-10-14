import Foundation

public struct EpisodeChapter: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var title: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval?

    public init(id: Int, title: String, startTime: TimeInterval, endTime: TimeInterval? = nil) {
        self.id = id
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
    }
}
