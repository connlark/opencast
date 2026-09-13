import AppIntents

struct PlayLatestOpenCastEpisodeIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Play Latest Unplayed Episode"
    nonisolated static var supportedModes: IntentModes { .foreground }
    nonisolated static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Show") var show: OpenCastPodcastEntity
    nonisolated static var parameterSummary: some ParameterSummary { Summary("Play the latest unplayed episode of \(\.$show)") }

    func perform() async throws -> some IntentResult {
        try await OpenCastIntentAccess.perform(.playLatest(show.id))
        return .result()
    }
}
