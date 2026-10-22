import Foundation
import SwiftUI
import Testing
@testable import OpenCast

@MainActor
@Suite("Downloads storage graph model")
struct DownloadsStorageGraphModelTests {
    @Test("Segments run largest first; ties go by title, then by podcast ID")
    func ordersLargestFirstWithTiebreaks() {
        let model = DownloadsStorageGraphModel.make(breakdowns: [
            breakdown("https://example.com/small.xml", title: "Small", bytes: 100),
            breakdown("https://example.com/b.xml", title: "Show 10", bytes: 500),
            breakdown("https://example.com/a.xml", title: "Show 9", bytes: 500),
            breakdown("https://example.com/twin-b.xml", title: "Twin", bytes: 300),
            breakdown("https://example.com/twin-a.xml", title: "Twin", bytes: 300),
            breakdown("https://example.com/large.xml", title: "Large", bytes: 900)
        ])

        #expect(model.segments.map(\.id) == [
            "https://example.com/large.xml",
            // Numeric-aware: "Show 9" sorts before "Show 10".
            "https://example.com/a.xml",
            "https://example.com/b.xml",
            "https://example.com/twin-a.xml",
            "https://example.com/twin-b.xml",
            "https://example.com/small.xml"
        ])
        #expect(model.segments.map(\.number) == [1, 2, 3, 4, 5, 6])
    }

    @Test("Six shows each keep a segment and no Other")
    func sixShowsHaveNoOther() {
        let model = DownloadsStorageGraphModel.make(breakdowns: (1...6).map { index in
            breakdown("https://example.com/\(index).xml", title: "Show \(index)", bytes: Int64(index) * 100)
        })

        let otherCount = model.segments.count { $0.isOther }
        let singleShowCount = model.segments.count { $0.members.count == 1 }
        #expect(model.segments.count == 6)
        #expect(otherCount == 0)
        #expect(singleShowCount == 6)
    }

    @Test("Seven shows fold the two smallest into Other with summed figures")
    func sevenShowsFoldIntoOther() throws {
        let model = DownloadsStorageGraphModel.make(breakdowns: (1...7).map { index in
            breakdown(
                "https://example.com/\(index).xml",
                title: "Show \(index)",
                episodes: index,
                bytes: Int64(index) * 100
            )
        })

        #expect(model.segments.count == DownloadsStorageGraphModel.maximumSegmentCount)
        #expect(model.segments.prefix(5).map(\.id) == (3...7).reversed().map { "https://example.com/\($0).xml" })
        let other = try #require(model.segments.last)
        #expect(other.isOther)
        #expect(other.id == DownloadsStorageGraphSegment.otherID)
        #expect(other.number == 6)
        #expect(other.title == "Other")
        #expect(other.byteCount == 300)
        #expect(other.episodeCount == 3)
        #expect(other.members.map(\.podcastID) == ["https://example.com/2.xml", "https://example.com/1.xml"])
        #expect(model.totalByteCount == 2_800)
        #expect(model.totalEpisodeCount == 28)
    }

    @Test("Fractions are each show's share and sum to one")
    func fractionsSumToOne() {
        let model = DownloadsStorageGraphModel.make(breakdowns: (1...9).map { index in
            breakdown("https://example.com/\(index).xml", title: "Show \(index)", bytes: Int64(index) * 37)
        })

        let sum = model.segments.reduce(0) { $0 + $1.fraction }
        #expect(abs(sum - 1) < 1e-9)
        #expect(abs(model.segments[0].fraction - 333.0 / 1_665.0) < 1e-12)
    }

    @Test("Nothing to draw when the downloads have no bytes")
    func zeroTotalHasNoSegments() {
        let model = DownloadsStorageGraphModel.make(breakdowns: [
            breakdown("https://example.com/a.xml", title: "A", episodes: 2, bytes: 0),
            breakdown("https://example.com/b.xml", title: "B", episodes: 1, bytes: -5)
        ])

        #expect(model.segments.isEmpty)
        #expect(model.totalByteCount == 0)
        #expect(model.totalEpisodeCount == 3)
        #expect(model.accessibilitySummary.isEmpty)
        #expect(DownloadsStorageGraphModel.make(breakdowns: []).segments.isEmpty)
    }

    @Test("The VoiceOver summary names each segment's share and size")
    func summaryWording() {
        let twoShows = DownloadsStorageGraphModel.make(breakdowns: [
            breakdown("https://example.com/b.xml", title: "Beta", bytes: 1_000),
            breakdown("https://example.com/a.xml", title: "Alpha", bytes: 3_000)
        ])
        #expect(
            twoShows.accessibilitySummary
                == "Alpha, 75 percent, \(DownloadsStorageText.size(3_000)); Beta, 25 percent, \(DownloadsStorageText.size(1_000))"
        )

        var breakdowns = (1...6).map { index in
            breakdown("https://example.com/\(index).xml", title: "Show \(index)", bytes: 100_000)
        }
        breakdowns.append(breakdown("https://example.com/tiny.xml", title: "Tiny", bytes: 1))
        let withOther = DownloadsStorageGraphModel.make(breakdowns: breakdowns)
        #expect(withOther.accessibilitySummary.hasSuffix(
            "2 other shows, 17 percent, \(DownloadsStorageText.size(100_001))"
        ))

        let sliver = DownloadsStorageGraphModel.make(breakdowns: [
            breakdown("https://example.com/big.xml", title: "Big", bytes: 100_000),
            breakdown("https://example.com/tiny.xml", title: "Tiny", bytes: 1)
        ])
        #expect(sliver.accessibilitySummary.hasSuffix("Tiny, less than 1 percent, \(DownloadsStorageText.size(1))"))
    }

    @Test("Shows take palette colors in bar order and Other is gray")
    func paletteIndices() throws {
        let model = DownloadsStorageGraphModel.make(breakdowns: (1...8).map { index in
            breakdown("https://example.com/\(index).xml", title: "Show \(index)", bytes: Int64(index) * 100)
        })

        #expect(model.segments.map(\.paletteIndex) == [0, 1, 2, 3, 4, nil])
        let palette = DownloadsStorageSegmentPalette.ordered
        #expect(palette.count >= DownloadsStorageGraphModel.maximumSegmentCount)
        #expect(Set(palette).count == palette.count)
        #expect(palette.prefix(5) == [.blue, .orange, .green, .purple, .teal])
        let first = try #require(model.segments.first)
        let other = try #require(model.segments.last)
        #expect(DownloadsStorageSegmentPalette.fill(for: first) == PlaylistTint.blue.color)
        #expect(DownloadsStorageSegmentPalette.digitColor == Color.black)
        #expect(DownloadsStorageSegmentPalette.fill(for: other) == Color.gray)

        let sixShows = DownloadsStorageGraphModel.make(breakdowns: (1...6).map { index in
            breakdown("https://example.com/\(index).xml", title: "Show \(index)", bytes: Int64(index) * 100)
        })
        let sixth = try #require(sixShows.segments.last)
        #expect(DownloadsStorageSegmentPalette.fill(for: sixth) == palette[5].color)
    }

    @Test("The animation key follows shape changes, not byte drift")
    func animationKeyIgnoresByteDrift() {
        let before = DownloadsStorageGraphModel.make(breakdowns: [
            breakdown("https://example.com/a.xml", title: "A", bytes: 1_000_000),
            breakdown("https://example.com/b.xml", title: "B", bytes: 1_000_000)
        ])
        let drifted = DownloadsStorageGraphModel.make(breakdowns: [
            breakdown("https://example.com/a.xml", title: "A", bytes: 1_000_010),
            breakdown("https://example.com/b.xml", title: "B", bytes: 1_000_000)
        ])
        let reshaped = DownloadsStorageGraphModel.make(breakdowns: [
            breakdown("https://example.com/a.xml", title: "A", bytes: 3_000_000),
            breakdown("https://example.com/b.xml", title: "B", bytes: 1_000_000)
        ])

        #expect(before.animationKey == drifted.animationKey)
        #expect(before.animationKey != reshaped.animationKey)
    }

    @Test("Segment widths fill the bar and keep every segment visible")
    func segmentWidthsFillTheBar() {
        let widths = DownloadsStorageGraphModel.segmentWidths(
            fractions: [0.97, 0.02, 0.01],
            totalWidth: 304,
            spacing: 2,
            minimumWidth: 4
        )
        #expect(abs(widths.reduce(0, +) - 300) < 1e-9)
        let narrowCount = widths.count { $0 < 4 }
        #expect(narrowCount == 0)
        #expect(widths[0] > widths[1] && widths[1] > widths[2])

        let cramped = DownloadsStorageGraphModel.segmentWidths(
            fractions: [0.5, 0.25, 0.25],
            totalWidth: 14,
            spacing: 2,
            minimumWidth: 4
        )
        let equalShare = 10.0 / 3
        #expect(cramped == [equalShare, equalShare, equalShare])
        #expect(DownloadsStorageGraphModel.segmentWidths(fractions: [], totalWidth: 100, spacing: 2, minimumWidth: 4).isEmpty)
    }

    private func breakdown(
        _ podcastID: String,
        title: String,
        episodes: Int = 1,
        bytes: Int64
    ) -> DownloadsPodcastBreakdown {
        DownloadsPodcastBreakdown(
            podcastID: podcastID,
            title: title,
            artworkURL: nil,
            episodeCount: episodes,
            byteCount: bytes,
            isOrphaned: false
        )
    }
}
