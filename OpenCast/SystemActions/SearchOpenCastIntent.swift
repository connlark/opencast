import AppIntents

struct SearchOpenCastIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Search OpenCast"
    nonisolated static var supportedModes: IntentModes { .foreground }
    nonisolated static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Search") var query: String
    nonisolated static var parameterSummary: some ParameterSummary { Summary("Search OpenCast for \(\.$query)") }

    func perform() async throws -> some IntentResult {
        try await OpenCastIntentAccess.perform(.search(query))
        return .result()
    }
}
