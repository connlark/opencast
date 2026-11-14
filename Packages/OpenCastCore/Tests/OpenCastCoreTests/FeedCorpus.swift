import Foundation
import OpenCastCore
import Testing

/// A whole podcast feed a publisher actually served, saved byte for byte under `Corpus/feeds/`
/// so episode text is pinned against what publishers really write, not only hand-made fixtures.
/// Where each feed came from is recorded in `Corpus/PROVENANCE.md`.
struct FeedCorpus: CustomTestStringConvertible, Sendable {
    let resource: String

    var testDescription: String { resource }

    func data() throws -> Data {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "xml", subdirectory: "Corpus/feeds") else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: "Corpus/feeds/\(resource).xml"])
        }
        return try Data(contentsOf: url)
    }

    /// Parsed once per test process; a feed outside `all` is parsed on every call.
    func snapshot() throws -> FeedSnapshot {
        guard let parsed = Self.snapshots[resource] else {
            return try parse()
        }
        return try parsed.get()
    }

    func episode(titled title: String) throws -> Episode {
        let matches = try snapshot().episodes.filter { $0.title == title }
        try #require(matches.count == 1, "\(matches.count) episodes in \(resource) are titled \(title)")
        return matches[0]
    }

    func episode(guid: String) throws -> Episode {
        let matches = try snapshot().episodes.filter { $0.guid == guid }
        try #require(matches.count == 1, "\(matches.count) episodes in \(resource) have GUID \(guid)")
        return matches[0]
    }

    private func parse() throws -> FeedSnapshot {
        try RSSFeedParser().parse(data: data(), feedURL: URL(string: "https://example.com/corpus/\(resource).xml")!)
    }

    // A lazily initialised static runs once per process however many tests race for it, so
    // every feed is parsed once without a lock. A missing or unparsable feed is cached as its
    // error (not a `#require` failure) so each test that asks for it records its own issue.
    private static let snapshots: [String: Result<FeedSnapshot, any Error>] = Dictionary(
        all.map { feed in (feed.resource, Result { try feed.parse() }) },
        uniquingKeysWith: { first, _ in first }
    )

    static let audacityToPodcast = FeedCorpus(resource: "audacitytopodcast")
    static let backupWrapUp = FeedCorpus(resource: "backupwrapup")
    static let buildYourSaaS = FeedCorpus(resource: "buildyoursaas")
    static let businessWithoutBS = FeedCorpus(resource: "businesswithoutbs")
    static let buzzcast = FeedCorpus(resource: "buzzcast")
    static let cheekyPint = FeedCorpus(resource: "cheekypint")
    static let coreHappiness = FeedCorpus(resource: "corehappiness")
    static let dwarkeshPodcast = FeedCorpus(resource: "dwarkeshpodcast")
    static let hrCoffeeTime = FeedCorpus(resource: "hrcoffeetime")
    static let investLikeTheBest = FeedCorpus(resource: "investlikethebest")
    static let noPriors = FeedCorpus(resource: "nopriors")
    static let podcasting20 = FeedCorpus(resource: "podcasting20")
    static let podcastInsider = FeedCorpus(resource: "podcastinsider")
    static let pragmaticEngineer = FeedCorpus(resource: "pragmaticengineer")

    static let all: [FeedCorpus] = [
        audacityToPodcast,
        backupWrapUp,
        buildYourSaaS,
        businessWithoutBS,
        buzzcast,
        cheekyPint,
        coreHappiness,
        dwarkeshPodcast,
        hrCoffeeTime,
        investLikeTheBest,
        noPriors,
        podcasting20,
        podcastInsider,
        pragmaticEngineer
    ]
}
