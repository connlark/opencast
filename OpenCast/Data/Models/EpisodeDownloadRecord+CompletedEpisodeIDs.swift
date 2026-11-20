import Foundation

extension Sequence where Element == EpisodeDownloadRecord {
    var completedEpisodeIDs: Set<String> {
        Set(compactMap { $0.state == .completed ? $0.episodeID : nil })
    }
}
