import Foundation

enum EpisodeMetadataChips {
    static func make(
        publishedAt: Date?,
        duration: TimeInterval?,
        progress: EpisodeProgressSummary?,
        isDownloaded: Bool,
        downloadedByteCount: Int64?,
        playlistCount: Int = 0
    ) -> [EpisodeMetadataChip] {
        var chips: [EpisodeMetadataChip] = []

        if let publishedAt {
            chips.append(.publishDate(publishedAt))
        }

        if let progress, !progress.isCompleted, progress.hasVisibleProgress, let remaining = progress.remaining {
            chips.append(.remaining(remaining.formattedEpisodeRemaining, fractionCompleted: progress.fractionCompleted))
        } else if let duration, duration > 0 {
            chips.append(.duration(PlaylistDurationFormat.short(duration)))
        }

        if isDownloaded {
            let fileSize = downloadedByteCount.flatMap { bytes in
                bytes > 0 ? bytes.formatted(.byteCount(style: .file)) : nil
            }
            chips.append(.downloaded(fileSize: fileSize))
        }

        if progress?.isCompleted == true {
            chips.append(.played)
        }

        if playlistCount >= 1 {
            chips.append(.playlists(count: playlistCount))
        }

        return chips
    }
}
