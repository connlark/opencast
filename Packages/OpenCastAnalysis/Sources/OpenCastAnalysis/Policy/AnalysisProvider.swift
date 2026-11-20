public enum AnalysisProvider: String, Sendable, Hashable, CaseIterable, Codable {
    case google
    case openai

    /// The only host this build sends the provider's key to.
    public var pinnedHost: String {
        switch self {
        case .google: "generativelanguage.googleapis.com"
        case .openai: "api.openai.com"
        }
    }

    public var thinkingLevels: Set<String> {
        switch self {
        case .google: ["low", "medium", "high"]
        case .openai: ["none", "low", "medium", "high"]
        }
    }
}
