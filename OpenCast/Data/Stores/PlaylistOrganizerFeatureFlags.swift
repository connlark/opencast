import Foundation

/// Gate for Make a Playlist. The entry stays hidden while `isEnabled` is
/// false; it is the one switch that removes the feature from a build.
enum PlaylistOrganizerFeatureFlags {
    nonisolated static let isEnabled = true
    /// The entry hides for shows with fewer cached episodes than this.
    nonisolated static let minimumEpisodeCount = 3

    #if DEBUG
    /// Lights the feature for one process regardless of `isEnabled`, so
    /// device QA and UI tests keep working if the flag is ever turned off.
    nonisolated static let enableArgument = "--playlist-organizer-enabled"
    nonisolated static let enableEnvironmentKey = "OPENCAST_PLAYLIST_ORGANIZER_ENABLED"
    #endif

    nonisolated static var isEnabledForProcess: Bool {
        #if DEBUG
        if isRequested(argument: enableArgument, environmentKey: enableEnvironmentKey) {
            return true
        }
        #endif
        return isEnabled
    }

    #if DEBUG
    private nonisolated static func isRequested(argument: String, environmentKey: String) -> Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains(argument) || processInfo.environment[environmentKey] == "1"
    }
    #endif
}
