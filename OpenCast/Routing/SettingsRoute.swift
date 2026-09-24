import Foundation

enum SettingsRoute: Hashable {
    case playback
    case inbox
    case appIcon
    case notifications
    case transcription
    case adSkipping
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
