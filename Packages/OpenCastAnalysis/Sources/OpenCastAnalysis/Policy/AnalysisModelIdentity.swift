public struct AnalysisModelIdentity: Sendable, Hashable {
    public var provider: AnalysisProvider
    public var modelID: String

    public init(provider: AnalysisProvider, modelID: String) {
        self.provider = provider
        self.modelID = modelID
    }
}
