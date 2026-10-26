import Foundation

/// One provider's token counts as this device saw them in provider
/// responses: the last finished run, and the totals of the UTC month named
/// by `month`.
nonisolated struct AnalysisProviderUsage: Codable, Equatable, Sendable {
    nonisolated struct Run: Codable, Equatable, Sendable {
        /// An `AnalysisFeature` raw value.
        var feature: String
        var inputTokens: Int
        var outputTokens: Int
        var at: Date
    }

    var lastRun: Run?
    /// `"yyyy-MM"`, Gregorian, in UTC.
    var month: String
    var monthInputTokens: Int
    var monthOutputTokens: Int
    /// The newest recorded runs with the totals already counted for each,
    /// so recording a run again (a finish retried after a relaunch, or a
    /// resumed run's larger totals) adds only what was not counted yet.
    var recentRuns: [CountedRun]? = nil

    nonisolated struct CountedRun: Codable, Equatable, Sendable {
        var id: String
        var inputTokens: Int
        var outputTokens: Int
    }

    static let recentRunLimit = 200
}
