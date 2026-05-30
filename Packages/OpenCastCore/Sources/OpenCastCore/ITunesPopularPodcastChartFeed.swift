import Foundation

struct ITunesPopularPodcastChartFeed: Decodable, Sendable {
    var results: [ITunesPopularPodcastChartResult]
}
