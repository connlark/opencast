import AppIntents

struct AddOpenCastEpisodeToPlaylistIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Add Episode to Playlist"
    nonisolated static var supportedModes: IntentModes { .foreground }
    nonisolated static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Episode") var episode: OpenCastEpisodeEntity
    @Parameter(title: "Playlist") var playlist: OpenCastPlaylistEntity
    nonisolated static var parameterSummary: some ParameterSummary { Summary("Add \(\.$episode) to \(\.$playlist)") }

    func perform() async throws -> some IntentResult {
        try await OpenCastIntentAccess.perform(.addToPlaylist(episodeID: episode.id, playlistID: playlist.id))
        return .result()
    }
}
