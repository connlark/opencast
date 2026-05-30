import Foundation

// DateFormatter and ISO8601DateFormatter are mutable reference types, so the cache serializes all access.
final class RSSDateFormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private let formatters: [DateFormatter]
    private let iso8601Formatter = ISO8601DateFormatter()

    init(formats: [String]) {
        formatters = formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
    }

    func date(from value: String) -> Date? {
        lock.lock()
        defer {
            lock.unlock()
        }

        for formatter in formatters {
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return iso8601Formatter.date(from: value)
    }
}
