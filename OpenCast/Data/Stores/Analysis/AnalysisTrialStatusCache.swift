import Foundation
import Observation

/// The install's last trial status, kept for an hour (and across launches)
/// so route resolution asks the trial service at most hourly. Every status
/// it reads is published to `onStatus`, which feeds the key notice.
@Observable
final class AnalysisTrialStatusCache {
    static let timeToLive: TimeInterval = 60 * 60
    static let preferenceKey = "analysis.trialStatus"

    private(set) var status: AnalysisTrialProxyStatus?
    private(set) var fetchedAt: Date?
    @ObservationIgnored var onStatus: ((AnalysisTrialStatus) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let fetch: () async -> AnalysisTrialProxyStatus?
    @ObservationIgnored private var inFlight: Task<AnalysisTrialProxyStatus?, Never>?

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date.now },
        fetch: @escaping () async -> AnalysisTrialProxyStatus?
    ) {
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
        if let data = defaults.data(forKey: Self.preferenceKey),
           let stored = try? Self.decoder.decode(Stored.self, from: data) {
            status = stored.status
            fetchedAt = stored.fetchedAt
        }
    }

    /// The status, from the cache when younger than an hour and not forced;
    /// `nil` when it could not be read.
    func status(forceRefresh: Bool) async -> AnalysisTrialProxyStatus? {
        if !forceRefresh, let status, let fetchedAt, now().timeIntervalSince(fetchedAt) < Self.timeToLive, fetchedAt <= now() {
            return status
        }
        if let inFlight { return await inFlight.value }
        let task = Task { await fetch() }
        inFlight = task
        let fetched = await task.value
        inFlight = nil
        guard let fetched else { return nil }
        store(fetched)
        return fetched
    }

    /// Forgets the cached status (Delete Data).
    func reset() {
        status = nil
        fetchedAt = nil
        defaults.removeObject(forKey: Self.preferenceKey)
    }

    private func store(_ fetched: AnalysisTrialProxyStatus) {
        status = fetched
        fetchedAt = now()
        if let data = try? Self.encoder.encode(Stored(status: fetched, fetchedAt: now())) {
            defaults.set(data, forKey: Self.preferenceKey)
        }
        onStatus?(fetched.trialStatus)
    }

    private struct Stored: Codable {
        var status: AnalysisTrialProxyStatus
        var fetchedAt: Date
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
