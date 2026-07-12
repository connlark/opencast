public nonisolated struct PlaybackAutoSkipEvent: Sendable, Equatable {
    public let zoneID: Int
    public let sequence: Int

    public init(zoneID: Int, sequence: Int) {
        self.zoneID = zoneID
        self.sequence = sequence
    }
}
