import Foundation

// ISO8601DateFormatter is mutable, so this helper serializes access to the shared fallback formatter.
final class RSSISO8601DateParser: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    func date(from value: String) -> Date? {
        lock.lock()
        defer {
            lock.unlock()
        }

        return formatter.date(from: value)
    }
}
