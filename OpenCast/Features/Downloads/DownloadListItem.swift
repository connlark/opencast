import Foundation

struct DownloadListItem: Identifiable {
    let record: EpisodeDownloadRecord
    let episode: EpisodeListItemSnapshot
    let isOrphaned: Bool

    var id: String {
        record.episodeID
    }

    static func make(record: EpisodeDownloadRecord, library: LibraryStore) -> DownloadListItem {
        if let episode = library.episode(with: record.episodeID) {
            return DownloadListItem(record: record, episode: episode, isOrphaned: false)
        }

        let podcastCache = library.podcastCache(for: record.podcastID)
        let episode = EpisodeListItemSnapshot(
            episodeID: record.episodeID,
            podcastID: record.podcastID,
            podcastTitle: nonempty(record.podcastTitle) ?? podcastCache?.title ?? "Removed Podcast",
            title: nonempty(record.episodeTitle) ?? humanizedAudioTitle(record.sourceAudioURL),
            summary: nil,
            publishedAt: record.publishedAt,
            duration: record.duration,
            audioURL: nonempty(record.sourceAudioURL),
            artworkURL: nonempty(record.artworkURLString) ?? podcastCache?.artworkURL,
            artworkPreview: podcastCache?.artworkPreview,
            guid: nil,
            cachedAt: record.updatedAt
        )
        return DownloadListItem(record: record, episode: episode, isOrphaned: true)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }

    private static func humanizedAudioTitle(_ sourceAudioURL: String) -> String {
        guard let url = URL(string: sourceAudioURL),
              let decodedName = url.deletingPathExtension().lastPathComponent.removingPercentEncoding
        else {
            return "Downloaded Episode"
        }

        let words = decodedName
            .replacing("-", with: " ")
            .replacing("_", with: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return words.isEmpty ? "Downloaded Episode" : words.capitalized
    }
}
