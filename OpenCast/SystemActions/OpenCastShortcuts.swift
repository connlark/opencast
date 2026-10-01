import AppIntents

nonisolated struct OpenCastShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ResumeOpenCastPlaybackIntent(), phrases: ["Resume playback in \(.applicationName)"], shortTitle: "Resume Playback", systemImageName: "play.fill")
        AppShortcut(intent: PlayOpenCastEpisodeIntent(), phrases: ["Play an episode in \(.applicationName)"], shortTitle: "Play Episode", systemImageName: "headphones")
        AppShortcut(intent: PlayLatestOpenCastEpisodeIntent(), phrases: ["Play the latest episode in \(.applicationName)", "Play the latest \(\.$show) in \(.applicationName)"], shortTitle: "Play Latest", systemImageName: "play.circle")
        AppShortcut(intent: AddOpenCastEpisodeToUpNextIntent(), phrases: ["Add to Up Next in \(.applicationName)"], shortTitle: "Add to Up Next", systemImageName: "text.line.last.and.arrowtriangle.forward")
        AppShortcut(intent: SearchOpenCastIntent(), phrases: ["Search in \(.applicationName)"], shortTitle: "Search", systemImageName: "magnifyingglass")
        AppShortcut(intent: PlayOpenCastPlaylistIntent(), phrases: ["Play my \(\.$playlist) playlist in \(.applicationName)", "Play a playlist in \(.applicationName)"], shortTitle: "Play Playlist", systemImageName: "music.note.list")
        AppShortcut(intent: AddOpenCastEpisodeToPlaylistIntent(), phrases: ["Add to a playlist in \(.applicationName)"], shortTitle: "Add to Playlist", systemImageName: "text.badge.plus")
    }
}
