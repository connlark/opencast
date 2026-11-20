import Foundation
import OpenCastCore
import Testing
@testable import OpenCast

@MainActor
@Suite("Downloads show groups")
struct DownloadsShowGroupTests {
    private let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())

    @Test("Groups follow each show's first, newest, download and keep the list's order inside")
    func groupsKeepFirstAppearanceOrder() {
        let items = [
            item("beta-1", podcastID: "https://example.com/beta.xml"),
            item("alpha-1", podcastID: "https://example.com/alpha.xml"),
            item("beta-2", podcastID: "https://example.com/beta.xml"),
            item("gamma-1", podcastID: "https://example.com/gamma.xml"),
            item("alpha-2", podcastID: "https://example.com/alpha.xml")
        ]

        let groups = DownloadsShowGroup.make(items: items, isSubscribed: { _ in true })

        #expect(groups.map(\.id) == [
            "https://example.com/beta.xml",
            "https://example.com/alpha.xml",
            "https://example.com/gamma.xml"
        ])
        #expect(groups.map { $0.items.map(\.id) } == [["beta-1", "beta-2"], ["alpha-1", "alpha-2"], ["gamma-1"]])
    }

    @Test("Each group counts its episodes and sums their bytes, ignoring negative sizes")
    func groupsCountAndSum() {
        let items = [
            item("a-1", podcastID: "https://example.com/a.xml", bytes: 1_000),
            item("b-1", podcastID: "https://example.com/b.xml", bytes: 250),
            item("a-2", podcastID: "https://example.com/a.xml", bytes: 2_500),
            item("a-3", podcastID: "https://example.com/a.xml", bytes: -40)
        ]

        let groups = DownloadsShowGroup.make(items: items, isSubscribed: { _ in true })

        #expect(groups.map(\.episodeCount) == [3, 1])
        #expect(groups.map(\.byteCount) == [3_500, 250])
    }

    private func item(
        _ episodeID: String,
        podcastID: String,
        bytes: Int64 = 100
    ) -> DownloadListItem {
        DownloadListItem.make(
            record: EpisodeDownloadRecord(
                episodeID: episodeID,
                podcastID: podcastID,
                sourceAudioURL: "https://example.com/\(episodeID).mp3",
                state: .completed,
                bytesReceived: bytes,
                episodeTitle: "Episode \(episodeID)",
                podcastTitle: "Show"
            ),
            library: library
        )
    }
}
