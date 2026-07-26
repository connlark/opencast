nonisolated struct CarPlayPodcastRow: Identifiable, Equatable, Sendable {
    let feedURL: String
    let title: String
    let artworkURL: String?

    var id: String {
        feedURL
    }
}
