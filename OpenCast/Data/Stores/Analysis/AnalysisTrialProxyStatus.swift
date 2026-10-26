import Foundation

/// The trial service's answer to `POST /v1/trial/status`.
nonisolated struct AnalysisTrialProxyStatus: Codable, Sendable, Hashable {
    enum Mode: String, Codable, Sendable, Hashable {
        /// Before the trial starts: every install is served without a count.
        case open
        case trial
    }

    var mode: Mode
    var unitsRemaining: Int
    var startsAt: Date
    var monthPaused: Bool

    enum CodingKeys: String, CodingKey {
        case mode
        case unitsRemaining = "units_remaining"
        case startsAt = "starts_at"
        case monthPaused = "month_paused"
    }

    /// The status the key notice and key screen show.
    var trialStatus: AnalysisTrialStatus {
        switch mode {
        case .open: .notStarted
        case .trial: unitsRemaining > 0 ? .unitsLeft(unitsRemaining) : .exhausted
        }
    }

    static func decode(_ data: Data) -> Self? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let status = try? decoder.decode(Self.self, from: data), status.unitsRemaining >= 0 else { return nil }
        return status
    }
}
