import Foundation

enum EpisodeDownloadState: String, Codable, CaseIterable, Sendable {
    case downloading
    case paused
    case completed
    case failed
    case missing
}
