import Foundation

enum SettingsRoute: Hashable {
    /// The Settings hub itself, for a stack other than the Settings tab's.
    case hub
    case playback
    case sleepTimer
    case autoAddToUpNext
    case lookAndFeel
    case appIcon
    case notifications
    case transcription
    case adSkipping
    case skipSound
    case aiServices
    case credits
    case sync
    case storage
    case importExport
    case help
    case helpTopic(id: String)
    case about
    case diagnostics
    case refreshLogs
    case deleteData
}
