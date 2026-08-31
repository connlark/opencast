import Foundation
import OpenCastPlayback

/// Shared row-value formatting: raw seconds with millisecond precision (so
/// boundary clamping is visible), ISO-8601 dates, and explicit sentinels
/// instead of empty strings.
nonisolated enum EpisodeDiagnosticsFormatting {
    static func value(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "None"
        }
        return value
    }

    static func seconds(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite else {
            return "Unavailable"
        }
        return "\(value.formatted(.number.precision(.fractionLength(3)).grouping(.never)))s"
    }

    static func date(_ value: Date?) -> String {
        guard let value else {
            return "None"
        }
        return value.formatted(.iso8601)
    }

    static func byteCount(_ value: Int64?) -> String {
        guard let value else {
            return "Unknown"
        }
        return "\(value) (\(value.formatted(.byteCount(style: .file))))"
    }

    static func bool(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    static func zone(_ zone: PlaybackSkipZone) -> String {
        "#\(zone.id) \(seconds(zone.startTime))–\(seconds(zone.endTime))"
    }

    static func zoneList(_ zones: [PlaybackSkipZone]) -> String {
        guard !zones.isEmpty else {
            return "None"
        }
        return zones.map(zone).joined(separator: "; ")
    }
}
