import AppIntents

struct PlayOpenCastEpisodeIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Play Episode"
    nonisolated static var supportedModes: IntentModes { .foreground }
    nonisolated static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Episode") var episode: OpenCastEpisodeEntity
    nonisolated static var parameterSummary: some ParameterSummary { Summary("Play \(\.$episode)") }

    func perform() async throws -> some IntentResult {
        try await OpenCastIntentAccess.perform(.playEpisode(episode.id))
        return .result()
    }
}
