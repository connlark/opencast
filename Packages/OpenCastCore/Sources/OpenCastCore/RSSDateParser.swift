import Foundation
import OpenCastDateParsing

enum RSSDateParser {
    static func parse(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let secondsSince1970 = parseInternetDate(trimmed) {
            return Date(timeIntervalSince1970: TimeInterval(secondsSince1970))
        }

        return parseISO8601(trimmed)
    }

    private static let iso8601 = Date.ISO8601FormatStyle()
    private static let iso8601WithFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func parseISO8601(_ value: String) -> Date? {
        if let date = try? iso8601.parse(value) {
            return date
        }
        return try? iso8601WithFractionalSeconds.parse(value)
    }

    private static func parseInternetDate(_ value: String) -> Int64? {
        value.withCString { input in
            var secondsSince1970: Int64 = 0
            guard OpenCastParseInternetDate(input, &secondsSince1970) else {
                return nil
            }
            return secondsSince1970
        }
    }
}
