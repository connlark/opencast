import Foundation

extension Date {
    /// The date with fractional seconds dropped, matching what an
    /// `.iso8601`-coded round trip through disk returns. Dates that are
    /// persisted via ISO-8601 JSON and later compared for equality must be
    /// minted or compared at this granularity.
    nonisolated var truncatedToWholeSeconds: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}
