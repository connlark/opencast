import OpenCastAnalysis

extension AnalysisProvider {
    /// The name rows and titles use: "Google Gemini", "OpenAI".
    nonisolated var displayName: String {
        AIServicesCopy.displayName(self)
    }

    /// The name sentences use: "Google", "OpenAI".
    nonisolated var shortName: String {
        AIServicesCopy.shortName(self)
    }
}
