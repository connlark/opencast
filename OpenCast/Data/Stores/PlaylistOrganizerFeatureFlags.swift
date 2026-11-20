import Foundation

enum PlaylistOrganizerFeatureFlags {
    nonisolated static let isEnabled = true
    nonisolated static let minimumEpisodeCount = 3

    #if DEBUG
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
