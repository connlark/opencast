import Foundation

extension Date {
    /// What an `.iso8601` round trip through disk returns. Dates persisted as ISO-8601 JSON and
    /// later compared for equality must be minted or compared at this granularity.
    nonisolated var truncatedToWholeSeconds: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}
