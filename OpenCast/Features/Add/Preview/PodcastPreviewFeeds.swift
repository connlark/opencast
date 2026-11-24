import OpenCastCore

struct PodcastPreviewFeeds {
    let recommended: PodcastPreviewFeed
    let other: PodcastPreviewFeed?
    let reason: DirectoryFeedChoice.Reason?

    var all: [PodcastPreviewFeed] {
        other.map { [recommended, $0] } ?? [recommended]
    }

    func feed(id: String?) -> PodcastPreviewFeed {
        all.first { $0.id == id } ?? recommended
    }

    static func read(_ outcome: DirectoryFeedResolution.Outcome) async throws -> PodcastPreviewFeeds {
        switch outcome {
        case .subscribe(let candidate):
            return PodcastPreviewFeeds(recommended: try await .read(candidate), other: nil, reason: nil)
        case .choice(let choice):
            async let recommended = PodcastPreviewFeed.read(choice.primary)
            async let other = PodcastPreviewFeed.read(choice.secondary)
            return PodcastPreviewFeeds(recommended: try await recommended, other: try await other, reason: choice.reason)
        }
    }
}
