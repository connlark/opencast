import Foundation

nonisolated struct ResumeWidgetCandidate: Equatable, Sendable {
    let episodeID: String
    let title: String
    let showTitle: String
    let artworkURL: URL?
    let artworkRevision: String?
    let progressBucket: Int
    let isPlaying: Bool
}
