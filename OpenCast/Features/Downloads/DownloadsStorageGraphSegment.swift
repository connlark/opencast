/// One stretch of the storage bar: a show, or the shows past the fifth
/// folded into Other.
struct DownloadsStorageGraphSegment: Identifiable {
    static let otherID = "downloads-storage-other"

    let id: String
    /// The 1-based position in the bar. Differentiate Without Color draws
    /// it in the segment and on its legend marker.
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

    /// Where the segment's color comes from in
    /// `DownloadsStorageSegmentPalette.ordered`; nil for Other's gray.
    var paletteIndex: Int? {
        isOther ? nil : number - 1
    }
}
