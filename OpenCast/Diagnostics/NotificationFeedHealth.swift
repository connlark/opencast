import Foundation

/// Advisory only: it never gates sync or subscribe, so a stale snapshot is acceptable.
nonisolated struct NotificationFeedHealth: Decodable, Equatable, Sendable {
    /// The server's exponential poll backoff makes polls stop being routine
    /// around this point; used only for advisory copy.
    static let degradedFailureThreshold = 3

    let consecutiveFailures: Int
    let lastHTTPStatus: Int?
    let lastError: String?
    let lastPolledAtEpochSeconds: Int?

    init(
        consecutiveFailures: Int,
        lastHTTPStatus: Int? = nil,
        lastError: String? = nil,
        lastPolledAtEpochSeconds: Int? = nil
    ) {
        self.consecutiveFailures = consecutiveFailures
        self.lastHTTPStatus = lastHTTPStatus
        self.lastError = lastError
        self.lastPolledAtEpochSeconds = lastPolledAtEpochSeconds
    }

    enum CodingKeys: String, CodingKey {
        case consecutiveFailures = "consecutive_failures"
        case lastHTTPStatus = "last_http_status"
        case lastError = "last_error"
        case lastPolledAtEpochSeconds = "last_polled_at"
    }

    var lastPolledAt: Date? {
        lastPolledAtEpochSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    var isDegraded: Bool {
        consecutiveFailures >= Self.degradedFailureThreshold
    }
}
