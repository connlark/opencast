import Foundation

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
    /// Totals already counted per run, so recording a run again (a retried finish, a resumed run's
    /// larger totals) adds only what was not counted yet.
    var recentRuns: [CountedRun]? = nil

    nonisolated struct CountedRun: Codable, Equatable, Sendable {
        var id: String
        var inputTokens: Int
        var outputTokens: Int
    }

    static let recentRunLimit = 200
}
