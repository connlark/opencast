import Foundation
import OpenCastCore

struct PodcastPreviewRequest: Identifiable, Hashable {
    enum Subject {
        case result(DirectoryPodcastResult)
        case feedURL(URL)
        case resolvedChoice(DirectoryPodcastResult, DirectoryFeedChoice)
    }

    let id: UUID
    let subject: Subject

    init(id: UUID = UUID(), subject: Subject) {
        self.id = id
        self.subject = subject
    }

    static func == (lhs: PodcastPreviewRequest, rhs: PodcastPreviewRequest) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var showID: String {
        switch subject {
        case .result(let result), .resolvedChoice(let result, _):
            result.id
        case .feedURL(let feedURL):
            URLCanonicalizer.canonicalString(for: feedURL)
        }
    }

    var knownPodcastKey: KnownPodcastsStore.Key {
        switch subject {
        case .result(let result), .resolvedChoice(let result, _):
            result.knownPodcastKey
        case .feedURL(let feedURL):
            KnownPodcastsStore.Key(resultID: nil, feedURLs: [URLCanonicalizer.canonicalString(for: feedURL)])
        }
    }
}
