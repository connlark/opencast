import Foundation

/// Internal debug gate for the pass-0 remote transcription slice. Not a
/// shipping preference: release builds compile to `false`, the backend
/// configuration is additionally disabled outside DEBUG, and with the flag
/// off no remote UI exists and no remote code path is reachable.
nonisolated enum RemoteTranscriptionDevFlag {
    static let defaultsKey = "debug.remoteTranscriptionDevEnabled"
    static let launchArgument = "-OPENCAST_REMOTE_TRANSCRIPTION_DEV"

    static var isEnabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: defaultsKey)
            || ProcessInfo.processInfo.arguments.contains(launchArgument)
        #else
        false
        #endif
    }

    #if DEBUG
    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
    }
    #endif
}
