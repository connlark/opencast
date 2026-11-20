public struct AnalysisPolicy<Settings: Sendable & Equatable>: Sendable, Equatable {
    public let bundleVersion: Int
    public let source: AnalysisPolicySource
    public let settings: Settings
    public let model: AnalysisModelEntry
    public let executionBudget: AnalysisExecutionBudget

    public init(
        bundleVersion: Int,
        source: AnalysisPolicySource,
        settings: Settings,
        model: AnalysisModelEntry,
        executionBudget: AnalysisExecutionBudget = .service
    ) {
        self.bundleVersion = bundleVersion
        self.source = source
        self.settings = settings
        self.model = model
        self.executionBudget = executionBudget
    }
}

public typealias AdDetectionAnalysisPolicy = AnalysisPolicy<AdDetectionPolicy>
public typealias ChaptersSummaryAnalysisPolicy = AnalysisPolicy<ChaptersSummaryPolicy>
