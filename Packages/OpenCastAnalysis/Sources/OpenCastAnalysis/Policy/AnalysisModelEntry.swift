/// One model a feature may run on, with the exact settings it was qualified
/// with. The picker shows `label`; the app sends the rest unchanged.
public struct AnalysisModelEntry: Sendable, Equatable, Decodable {
    public var provider: AnalysisProvider
    public var modelID: String
    public var label: String
    /// Provider-neutral thinking level: Gemini `thinkingLevel`, OpenAI
    /// `reasoning.effort`.
    public var thinking: String
    public var maxOutputTokens: Int
    /// Upper bound for one provider call; the pipeline may allot less when a
    /// run needs several waves of windows.
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
}

/// Decodes a model list, skipping entries whose provider this build does
/// not know so a later bundle can add a provider without failing older apps.
/// An entry for a known provider must decode completely.
struct KnownProviderModelEntries: Decodable {
    let entries: [AnalysisModelEntry]

    private struct Element: Decodable {
        let entry: AnalysisModelEntry?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnalysisModelEntry.CodingKeys.self)
            let provider = try container.decode(String.self, forKey: .provider)
            entry = AnalysisProvider(rawValue: provider) == nil
                ? nil
                : try AnalysisModelEntry(from: decoder)
        }
    }

    init(from decoder: any Decoder) throws {
        entries = try [Element](from: decoder).compactMap(\.entry)
    }
}
