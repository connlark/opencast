import Foundation

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
