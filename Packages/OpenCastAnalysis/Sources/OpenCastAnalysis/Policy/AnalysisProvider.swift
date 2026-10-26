/// A model provider the app can call directly with the listener's key.
/// Bundle entries naming any other provider are ignored by this build, so a
/// later bundle can add one without failing older apps.
public enum AnalysisProvider: String, Sendable, Hashable, CaseIterable, Codable {
    case google
    case openai

    /// The only host this build sends the provider's key to. A bundle that
    /// names another host for the provider is rejected whole.
    public var pinnedHost: String {
        switch self {
        case .google: "generativelanguage.googleapis.com"
        case .openai: "api.openai.com"
        }
    }

    /// The thinking levels the provider accepts for its golden models.
    public var thinkingLevels: Set<String> {
        switch self {
        case .google: ["low", "medium", "high"]
        case .openai: ["none", "low", "medium", "high"]
        }
    }
}
