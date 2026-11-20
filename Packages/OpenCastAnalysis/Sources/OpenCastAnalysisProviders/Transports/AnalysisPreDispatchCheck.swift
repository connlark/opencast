/// Runs after the pacer admits a send, right before it leaves: a classification refuses the send
/// unsent, `nil` lets it go.
public typealias AnalysisPreDispatchCheck = @Sendable () async -> AnalysisProviderErrorClassification?
