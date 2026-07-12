import Foundation

public nonisolated struct PlaybackSkipZone: Identifiable, Sendable, Equatable {
    public let id: Int
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(id: Int, startTime: TimeInterval, endTime: TimeInterval) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
    }
}
