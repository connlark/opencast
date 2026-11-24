import Foundation

public struct FeedDigest: Hashable, Sendable {
    public var newestEpisodes: [Episode]
    public var newestPublishedAt: Date?
    public var oldestPublishedAt: Date?
    /// Twelve Gregorian months, oldest first, ending with the reference date's month.
    public var monthlyEpisodeCounts: [Int]
    public var cadence: FeedCadence?
    public var isStopped: Bool

    public init(
        newestEpisodes: [Episode],
        newestPublishedAt: Date?,
        oldestPublishedAt: Date?,
        monthlyEpisodeCounts: [Int],
        cadence: FeedCadence?,
        isStopped: Bool
    ) {
        self.newestEpisodes = newestEpisodes
        self.newestPublishedAt = newestPublishedAt
        self.oldestPublishedAt = oldestPublishedAt
        self.monthlyEpisodeCounts = monthlyEpisodeCounts
        self.cadence = cadence
        self.isStopped = isStopped
    }
}

extension PreparedFeed {
    @concurrent
    public func digest(newest limit: Int, asOf referenceDate: Date, timeZone: TimeZone) async throws -> FeedDigest {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        // Counted from the day's labels: `ordinality(of: .day, in: .era)` ignores the time zone, and
        // elapsed time comes up a day short where a day starts after midnight.
        func dayNumber(_ date: Date) -> Int {
            let parts = gregorian.dateComponents([.year, .dayOfYear], from: date)
            let years = (parts.year ?? 1) - 1
            return years * 365 + years / 4 - years / 100 + years / 400 + (parts.dayOfYear ?? 0)
        }
        func monthNumber(_ date: Date) -> Int {
            let parts = gregorian.dateComponents([.year, .month], from: date)
            return (parts.year ?? 0) * 12 + (parts.month ?? 0)
        }
        let referenceMonth = monthNumber(referenceDate)
        var monthlyCounts = Array(repeating: 0, count: 12)
        var releaseDays: Set<Int> = []
        var dated: [(date: Date, episode: Episode)] = []
        var undated: [Episode] = []
        var oldest: Date?
        try episodes.forEachBatch { batch in
            for episode in batch {
                guard let date = episode.publishedAt else {
                    if dated.count + undated.count < limit { undated.append(episode) }
                    continue
                }
                oldest = min(oldest ?? date, date)
                let bar = 11 - referenceMonth + monthNumber(date)
                if monthlyCounts.indices.contains(bar) {
                    monthlyCounts[bar] += 1
                    releaseDays.insert(dayNumber(date))
                }
                let rank = dated.firstIndex { $0.date < date } ?? dated.count
                guard rank < limit else { continue }
                dated.insert((date, episode), at: rank)
                if dated.count + undated.count > limit {
                    if undated.isEmpty { dated.removeLast() } else { undated.removeLast() }
                }
            }
        }

        let days = releaseDays.sorted()
        let gaps = zip(days, days.dropFirst()).map { $1 - $0 }
        let sortedGaps = gaps.sorted()
        let medianGap = sortedGaps.isEmpty ? nil : sortedGaps[(sortedGaps.count - 1) / 2]
        let silence = episodes.newestPublishedAt.map { dayNumber(referenceDate) - dayNumber($0) }
        return FeedDigest(
            newestEpisodes: dated.map(\.episode) + undated,
            newestPublishedAt: episodes.newestPublishedAt,
            oldestPublishedAt: oldest,
            monthlyEpisodeCounts: monthlyCounts,
            cadence: medianGap.flatMap { FeedCadence(releaseGaps: gaps, medianGap: $0) },
            isStopped: silence.map { $0 > max(60, 3 * (medianGap ?? 0)) } ?? false
        )
    }
}
