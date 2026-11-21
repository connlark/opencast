public struct AnalysisModelCard: Sendable, Equatable, Decodable {
    public var provider: AnalysisProvider
    public var modelID: String
    public var price: String
    public var strengths: [String]
    public var weaknesses: [String]

    enum CodingKeys: String, CodingKey {
        case provider
        case modelID = "model_id"
        case price
        case strengths
        case weaknesses
    }

    public var identity: AnalysisModelIdentity {
        AnalysisModelIdentity(provider: provider, modelID: modelID)
    }
}
