import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode metadata chips")
struct EpisodeMetadataChipsTests {
    private let publishedAt = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("Publish date and duration render for a fresh episode")
    func freshEpisode() {
        let chips = EpisodeMetadataChips.make(
            publishedAt: publishedAt,
            duration: 10_020,
            progress: nil,
            isDownloaded: false,
            downloadedByteCount: nil
        )

        #expect(chips == [.publishDate(publishedAt), .duration("2h 47m")])
    }

    @Test("Visible progress swaps the duration chip for a remaining chip")
    func remainingReplacesDuration() {
        let progress = EpisodeProgressSummary(
            position: 600,
            duration: 12_000,
            fractionCompleted: 0.3,
            remaining: 10_020,
            isCompleted: false
        )

        let chips = EpisodeMetadataChips.make(
            publishedAt: nil,
            duration: 12_000,
            progress: progress,
            isDownloaded: false,
            downloadedByteCount: nil
        )

        #expect(chips == [.remaining("2h 47m left", fractionCompleted: 0.3)])
    }

    @Test("A played episode keeps its duration and gains a Played chip")
    func playedEpisode() {
        let progress = EpisodeProgressSummary(
            position: 12_000,
            duration: 12_000,
            fractionCompleted: 1,
            remaining: 0,
            isCompleted: true
        )

        let chips = EpisodeMetadataChips.make(
            publishedAt: publishedAt,
            duration: 12_000,
            progress: progress,
            isDownloaded: false,
            downloadedByteCount: nil
        )

        #expect(chips == [.publishDate(publishedAt), .duration("3h 20m"), .played])
    }

    @Test("Downloaded chip omits an unknown or zero size")
    func downloadedWithoutSize() {
        let chips = EpisodeMetadataChips.make(
            publishedAt: nil,
            duration: nil,
            progress: nil,
            isDownloaded: true,
            downloadedByteCount: 0
        )

        #expect(chips == [.downloaded(fileSize: nil)])
    }

    @Test("Duration formatting covers minute, hour, and mixed lengths")
    func durationFormatting() {
        #expect(durationChipText(300) == "5m")
        #expect(durationChipText(3_600) == "1h")
        #expect(durationChipText(3_660) == "1h 1m")
        #expect(durationChipText(30) == "1m")
    }

    private func durationChipText(_ duration: TimeInterval) -> String? {
        let chips = EpisodeMetadataChips.make(
            publishedAt: nil,
            duration: duration,
            progress: nil,
            isDownloaded: false,
            downloadedByteCount: nil
        )
        guard case .duration(let text)? = chips.first else {
            return nil
        }
        return text
    }
}
