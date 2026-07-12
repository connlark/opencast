import Foundation

enum EpisodeTranscriptState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
    case interrupted
}
