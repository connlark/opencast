import AppIntents

struct PlayOpenCastPlaylistIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Play Playlist"
    nonisolated static var supportedModes: IntentModes { .foreground }
    nonisolated static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Playlist") var playlist: OpenCastPlaylistEntity
    nonisolated static var parameterSummary: some ParameterSummary { Summary("Play \(\.$playlist)") }

    func perform() async throws -> some IntentResult {
        try await OpenCastIntentAccess.perform(.playPlaylist(playlist.id))
        return .result()
    }
}
