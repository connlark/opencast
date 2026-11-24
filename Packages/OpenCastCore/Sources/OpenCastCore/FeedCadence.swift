public enum FeedCadence: CaseIterable, Hashable, Sendable {
    case daily
    case weekly
    case everyTwoWeeks
    case monthly

    init?(releaseGaps gaps: [Int], medianGap: Int) {
        guard gaps.count >= 3,
              let cadence = Self.allCases.first(where: { $0.gapBand.contains(medianGap) }),
              gaps.count(where: cadence.gapBand.contains) * 2 > gaps.count
        else { return nil }
        self = cadence
    }

    private var gapBand: ClosedRange<Int> {
        switch self {
        case .daily: 1...1
        case .weekly: 6...8
        case .everyTwoWeeks: 13...15
        case .monthly: 27...36
        }
    }
}
