import Foundation

enum SettingsRoute: Hashable {
    case playback
    case sleepTimer
    case autoAddToUpNext
    case lookAndFeel
    case appIcon
    case notifications
    case transcription
    case adSkipping
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
