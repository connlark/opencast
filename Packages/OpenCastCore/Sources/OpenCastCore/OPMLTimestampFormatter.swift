import Foundation

final class OPMLTimestampFormatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    func string(from date: Date) -> String {
        lock.lock()
        defer {
            lock.unlock()
        }

        return formatter.string(from: date)
    }
}
