import Foundation

public struct EpisodeID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    public var rawValue: String

    public var id: String {
        rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
