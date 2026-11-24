import Foundation
import OpenCastCore
import SwiftUI

enum PodcastPreviewPreviewSamples {
    static func sheet(
        header: PodcastPreviewHeader,
        state: PodcastPreviewStore.State,
        action: PodcastPreviewActionBar.Action? = nil,
        isInLibrary: Bool = false,
        isExpanded: Bool = false
    ) -> some View {
        PodcastPreviewSampleSheetHost(detent: isExpanded ? .large : .medium) {
            results([
                (theSignal, isInLibrary && header.title == theSignal.title ? .justAdded : .addable),
                (signalAndNoise, .inLibrary),
                (theSignalPath, .addable),
            ])
        } sheet: {
            PodcastPreviewView(
                header: header,
                state: state,
                selectedFeedID: .constant(nil),
                action: action,
                isInLibrary: isInLibrary,
                isExpanded: isExpanded,
                onClose: {},
                onRetry: {},
                onSubscribe: {},
                onGoToShow: {}
            )
        }
    }

    static func results(_ rows: [(result: DirectoryPodcastResult, status: PodcastResultRow.Status)]) -> some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows, id: \.result.id) { row in
                        PodcastResultRow(result: row.result, status: row.status, openHint: "", onOpen: {}, onAdd: {})
                    }
                } header: {
                    Text("Results")
                } footer: {
                    PodcastIndexAttributionFooter(results: rows.map(\.result))
                }
            }
            .navigationTitle("Search")
        }
    }

    static let theSignal = DirectoryPodcastResult(id: 1, title: "The Signal", artistName: "Northfield Public Radio")
    static let signalAndNoise = DirectoryPodcastResult(id: 2, title: "Signal & Noise", artistName: "Priya Raman & Tom Okafor")
    static let theSignalPath = DirectoryPodcastResult(id: 3, title: "The Signal Path", artistName: "Halden Audio")
    static let nightSignal = DirectoryPodcastResult(
        id: "podcastindex:4",
        title: "Night Signal",
        artistName: "Ashgrove Fiction",
        sources: [.podcastIndex],
        feedCandidates: []
    )
    static let signalCastLive = DirectoryPodcastResult(id: 5, title: "SignalCast Live", artistName: "Meridian Media")

    fileprivate static func daysAgo(_ days: Double) -> Date {
        Date.now.addingTimeInterval(-days * 86_400)
    }

    fileprivate static func feed(
        url: String,
        title: String,
        summary: String,
        episodeCount: Int,
        episodes: [(title: String, date: Date, minutes: Double)],
        oldest: Date,
        monthly: [Int],
        cadence: FeedCadence?,
        isStopped: Bool = false
    ) -> PodcastPreviewFeed {
        let feedURL = URL(string: url)!
        let podcastID = URLCanonicalizer.podcastID(for: feedURL)
        let newest = episodes.enumerated().map { index, episode in
            Episode(
                id: EpisodeID(rawValue: "\(url)#\(index)"),
                podcastID: podcastID,
                podcastTitle: title,
                title: episode.title,
                publishedAt: episode.date,
                duration: episode.minutes * 60
            )
        }
        let older = (newest.count..<episodeCount).map { index in
            Episode(id: EpisodeID(rawValue: "\(url)#\(index)"), podcastID: podcastID, podcastTitle: title, title: "Episode")
        }
        let candidate = ResolvedFeedCandidate(
            candidate: DirectoryFeedCandidate(source: .apple, feedURL: feedURL),
            snapshot: FeedSnapshot(
                podcast: Podcast(id: podcastID, feedURL: feedURL, title: title, summary: summary),
                episodes: newest + older
            )
        )
        let digest = FeedDigest(
            newestEpisodes: newest,
            newestPublishedAt: newest.first?.publishedAt,
            oldestPublishedAt: oldest,
            monthlyEpisodeCounts: monthly,
            cadence: cadence,
            isStopped: isStopped
        )
        return PodcastPreviewFeed(candidate: candidate, digest: digest)
    }
}

extension PodcastPreviewHeader {
    static let signal = PodcastPreviewHeader(title: "The Signal", author: "Northfield Public Radio", genre: "News")
    static let signalPath = PodcastPreviewHeader(title: "The Signal Path", author: "Halden Audio", genre: "Music")
    static let longWayHome = PodcastPreviewHeader(
        title: "The Long Way Home",
        author: "Sable & Finch",
        genre: "Society & Culture"
    )
}

extension PodcastPreviewFeeds {
    static var signal: PodcastPreviewFeeds {
        let feed = PodcastPreviewPreviewSamples.feed(
            url: "https://feeds.northfield.example.com/the-signal.xml",
            title: "The Signal",
            summary: "The Signal is Northfield Public Radio’s daily news podcast. Every weekday morning, host June Adeyemi and the newsroom pick the one story worth your twenty minutes and take it apart with the reporters who covered it.",
            episodeCount: 1_412,
            episodes: [
                ("The Water Bill Nobody Read", PodcastPreviewPreviewSamples.daysAgo(0), 24),
                ("Why Your Flight Was Cancelled Last Week", PodcastPreviewPreviewSamples.daysAgo(3), 23),
                ("The Last Dairy in Harlan County", PodcastPreviewPreviewSamples.daysAgo(4), 27),
                ("The School Phone Ban, One Semester In", PodcastPreviewPreviewSamples.daysAgo(5), 26),
                ("A Bridge, a Budget, and a Deadline", PodcastPreviewPreviewSamples.daysAgo(6), 22),
                ("The Night Shift at County General", PodcastPreviewPreviewSamples.daysAgo(7), 28),
                ("What the Flu Numbers Are Telling Us", PodcastPreviewPreviewSamples.daysAgo(10), 21),
                ("Small Towns, Big Data Centers", PodcastPreviewPreviewSamples.daysAgo(11), 26),
            ],
            oldest: Date(timeIntervalSince1970: 1_612_137_600),
            monthly: [22, 21, 23, 22, 21, 22, 23, 21, 22, 23, 22, 18],
            cadence: .daily
        )
        return PodcastPreviewFeeds(recommended: feed, other: nil, reason: nil)
    }

    static var signalPath: PodcastPreviewFeeds {
        let feed = PodcastPreviewPreviewSamples.feed(
            url: "https://feeds.example.com/the-signal-path.xml",
            title: "The Signal Path",
            summary: "The Signal Path is a show about how sound gets made, from the microphone to the master. Producer Eli Halden sits down with engineers, synth builders and the people who still fix tape machines.",
            episodeCount: 58,
            episodes: [
                ("A Short Break (and Thank You)", Date(timeIntervalSince1970: 1_678_838_400), 18),
                ("Tape Delay, Explained by People Who Still Use It", Date(timeIntervalSince1970: 1_676_332_800), 53),
                ("Building a Synth From a Kit", Date(timeIntervalSince1970: 1_673_913_600), 61),
            ],
            oldest: Date(timeIntervalSince1970: 1_559_347_200),
            monthly: Array(repeating: 0, count: 12),
            cadence: nil,
            isStopped: true
        )
        return PodcastPreviewFeeds(recommended: feed, other: nil, reason: nil)
    }

    static var longWayHome: PodcastPreviewFeeds {
        let episodes: [(title: String, date: Date, minutes: Double)] = [
            ("The Border at Dawn", PodcastPreviewPreviewSamples.daysAgo(7), 52),
            ("What the Notebook Leaves Out", PodcastPreviewPreviewSamples.daysAgo(14), 48),
            ("The Farmhouse at Mile 1,400", PodcastPreviewPreviewSamples.daysAgo(21), 55),
        ]
        let summary = "The Long Way Home follows people trying to get back to somewhere they left a long time ago. Each season is one story, told over many weeks by the people who lived it."
        let monthly = [0, 0, 0, 1, 4, 4, 5, 4, 4, 4, 4, 2]
        let archive = PodcastPreviewPreviewSamples.feed(
            url: "https://archive.example.com/long-way-home.xml",
            title: "The Long Way Home",
            summary: summary,
            episodeCount: 124,
            episodes: episodes,
            oldest: Date(timeIntervalSince1970: 1_546_300_800),
            monthly: monthly,
            cadence: .weekly
        )
        let recent = PodcastPreviewPreviewSamples.feed(
            url: "https://feeds.example.com/long-way-home.xml",
            title: "The Long Way Home",
            summary: summary,
            episodeCount: 33,
            episodes: episodes,
            oldest: Date(timeIntervalSince1970: 1_717_200_000),
            monthly: monthly,
            cadence: .weekly
        )
        return PodcastPreviewFeeds(recommended: archive, other: recent, reason: .fullerFeedPromoted)
    }
}
