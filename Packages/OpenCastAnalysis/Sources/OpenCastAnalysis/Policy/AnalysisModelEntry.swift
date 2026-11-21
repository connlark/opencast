public struct AnalysisModelEntry: Sendable, Equatable, Decodable {
    public var provider: AnalysisProvider
    public var modelID: String
    public var label: String
    /// Provider-neutral: Gemini `thinkingLevel`, OpenAI `reasoning.effort`.
    public var thinking: String
    public var maxOutputTokens: Int
    /// An upper bound: a run with several waves of windows may allot a call less.
    public var perCallTimeoutSeconds: Int
    /// Wall-clock allowance for the whole run, retries and repair included.
    public var runBudgetSeconds: Int

    enum CodingKeys: String, CodingKey {
        case provider
        case modelID = "model_id"
        case label
        case thinking
        case maxOutputTokens = "max_output_tokens"
        case perCallTimeoutSeconds = "per_call_timeout_seconds"
        case runBudgetSeconds = "run_budget_seconds"
    }

    public var identity: AnalysisModelIdentity {
        AnalysisModelIdentity(provider: provider, modelID: modelID)
    }
}

/// Skips items whose provider this build does not know, so a later bundle can add a provider
/// without failing older apps.
struct KnownProviderList<Item: Decodable>: Decodable {
    let items: [Item]
    let skippedCount: Int

    private struct Element: Decodable {
        let item: Item?

        private enum CodingKeys: String, CodingKey {
            case provider
        }

        init(from decoder: any Decoder) throws {
            let provider = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .provider)
            item = AnalysisProvider(rawValue: provider) == nil ? nil : try Item(from: decoder)
        }
    }

    init(from decoder: any Decoder) throws {
        let elements = try [Element](from: decoder)
        items = elements.compactMap(\.item)
        skippedCount = elements.count - items.count
    }
}
