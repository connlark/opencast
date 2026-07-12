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

        return iso8601DateParser.date(from: trimmed)
    }

    private static let iso8601DateParser = RSSISO8601DateParser()

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
