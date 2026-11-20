struct DownloadsStorageGraphSegment: Identifiable {
    static let otherID = "downloads-storage-other"

    let id: String
    /// 1-based.
    let number: Int
    let title: String
    let byteCount: Int64
    let episodeCount: Int
    /// The segment's share of the bar; the bar's fractions sum to 1.
    let fraction: Double
    /// The one show a segment stands for, or Other's shows, largest first.
    let members: [DownloadsPodcastBreakdown]

    var isOther: Bool {
        id == Self.otherID
    }

    var paletteIndex: Int? {
        isOther ? nil : number - 1
    }
}
