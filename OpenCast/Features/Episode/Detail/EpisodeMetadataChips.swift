import Foundation

enum EpisodeMetadataChips {
    static func make(
        publishedAt: Date?,
        duration: TimeInterval?,
        progress: EpisodeProgressSummary?,
        isDownloaded: Bool,
        downloadedByteCount: Int64?
    ) -> [EpisodeMetadataChip] {
        var chips: [EpisodeMetadataChip] = []

        if let publishedAt {
            chips.append(.publishDate(publishedAt))
        }

        if let progress, !progress.isCompleted, progress.hasVisibleProgress, let remaining = progress.remaining {
            chips.append(.remaining(remaining.formattedEpisodeRemaining, fractionCompleted: progress.fractionCompleted))
        } else if let duration, duration > 0 {
            chips.append(.duration(formattedDuration(duration)))
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

        return chips
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = max(Int((duration / 60).rounded()), 1)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0, minutes > 0 {
            return "\(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(minutes)m"
    }
}
