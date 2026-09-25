import Foundation

extension Sequence where Element == EpisodeDownloadRecord {
    /// The episode IDs with a completed download on this device.
    var completedEpisodeIDs: Set<String> {
        Set(compactMap { $0.state == .completed ? $0.episodeID : nil })
    }
}
