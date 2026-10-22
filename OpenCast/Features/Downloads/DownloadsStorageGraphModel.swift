/// What the Downloads storage bar draws: completed downloads by show,
/// largest first. Up to six shows each get a segment; past six, the five
/// largest keep theirs and the rest share Other, so every segment stays wide
/// enough to see and to number.
struct DownloadsStorageGraphModel {
    static let maximumSegmentCount = 6

    let segments: [DownloadsStorageGraphSegment]
    let totalByteCount: Int64
    let totalEpisodeCount: Int

    /// The bar's VoiceOver value: "Show A, 45 percent, 1.2 GB; …".
    var accessibilitySummary: String {
        segments.map { segment in
            let name = segment.isOther ? "\(segment.members.count) other shows" : segment.title
            return "\(name), \(Self.percentText(segment.fraction)), \(DownloadsStorageText.size(segment.byteCount))"
        }
        .joined(separator: "; ")
    }

    /// Changes when the bar's shape does, ignoring byte-level drift.
    var animationKey: [String] {
        segments.map { "\($0.id)=\(Int(($0.fraction * 1000).rounded()))" }
    }

    static func make(breakdowns: [DownloadsPodcastBreakdown]) -> DownloadsStorageGraphModel {
        let ordered = breakdowns.sorted(by: largestFirst)
        let totalByteCount = ordered.reduce(Int64(0)) { $0 + max($1.byteCount, 0) }
        let totalEpisodeCount = ordered.reduce(0) { $0 + $1.episodeCount }
        guard totalByteCount > 0 else {
            return DownloadsStorageGraphModel(
                segments: [],
                totalByteCount: totalByteCount,
                totalEpisodeCount: totalEpisodeCount
            )
        }

        let foldsIntoOther = ordered.count > maximumSegmentCount
        let shownShows = foldsIntoOther ? Array(ordered.prefix(maximumSegmentCount - 1)) : ordered
        var segments = shownShows.enumerated().map { index, breakdown in
            DownloadsStorageGraphSegment(
                id: breakdown.podcastID,
                number: index + 1,
                title: breakdown.title,
                byteCount: max(breakdown.byteCount, 0),
                episodeCount: breakdown.episodeCount,
                fraction: Double(max(breakdown.byteCount, 0)) / Double(totalByteCount),
                members: [breakdown]
            )
        }
        if foldsIntoOther {
            let members = Array(ordered.dropFirst(maximumSegmentCount - 1))
            let byteCount = members.reduce(Int64(0)) { $0 + max($1.byteCount, 0) }
            segments.append(
                DownloadsStorageGraphSegment(
                    id: DownloadsStorageGraphSegment.otherID,
                    number: segments.count + 1,
                    title: "Other",
                    byteCount: byteCount,
                    episodeCount: members.reduce(0) { $0 + $1.episodeCount },
                    fraction: Double(byteCount) / Double(totalByteCount),
                    members: members
                )
            )
        }
        return DownloadsStorageGraphModel(
            segments: segments,
            totalByteCount: totalByteCount,
            totalEpisodeCount: totalEpisodeCount
        )
    }

    /// Segment widths for a bar `totalWidth` wide: each segment gets
    /// `minimumWidth`, and the rest of the bar is shared by fraction, so the
    /// widths always fill the bar exactly.
    static func segmentWidths(
        fractions: [Double],
        totalWidth: Double,
        spacing: Double,
        minimumWidth: Double
    ) -> [Double] {
        guard !fractions.isEmpty else {
            return []
        }
        let available = max(totalWidth - spacing * Double(fractions.count - 1), 0)
        let reserved = minimumWidth * Double(fractions.count)
        guard available > reserved else {
            return fractions.map { _ in available / Double(fractions.count) }
        }
        return fractions.map { minimumWidth + (available - reserved) * $0 }
    }

    private static func largestFirst(_ lhs: DownloadsPodcastBreakdown, _ rhs: DownloadsPodcastBreakdown) -> Bool {
        if lhs.byteCount != rhs.byteCount {
            return lhs.byteCount > rhs.byteCount
        }
        let comparison = lhs.title.localizedStandardCompare(rhs.title)
        return comparison == .orderedSame ? lhs.podcastID < rhs.podcastID : comparison == .orderedAscending
    }

    /// "45 percent"; a sliver reads "less than 1 percent" rather than zero.
    private static func percentText(_ fraction: Double) -> String {
        let percent = Int((fraction * 100).rounded())
        return percent == 0 && fraction > 0 ? "less than 1 percent" : "\(percent) percent"
    }
}
