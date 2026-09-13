import AppIntents

struct AddOpenCastEpisodeToUpNextIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Add Episode to Up Next"
    nonisolated static var supportedModes: IntentModes { .foreground }
    nonisolated static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Episode") var episode: OpenCastEpisodeEntity
    nonisolated static var parameterSummary: some ParameterSummary { Summary("Add \(\.$episode) to Up Next") }

    func perform() async throws -> some IntentResult {
        try await OpenCastIntentAccess.perform(.enqueue(episode.id))
        return .result()
    }
}
