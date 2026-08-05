import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Feed relocation advisor")
struct FeedRelocationAdvisorTests {
    private let feedURLString = "https://old.example.com/feed.xml"
    private let divergedURL = URL(string: "https://new.example.com/feed.xml")!
    private let otherDivergedURL = URL(string: "https://elsewhere.example.com/feed.xml")!
    private let sameHostURL = URL(string: "https://old.example.com/feed-v2.xml")!

    @Test("Suggestion trips at the third consecutive same-target divergence")
    func suggestionTripsAtThirdConsecutiveSameTargetDivergence() {
        var advisor = FeedRelocationAdvisor()

        let verdicts = (0..<4).map { _ in
            advisor.recordRedirect(feedURLString: feedURLString, finalURL: divergedURL)
        }

        // Past the threshold the suggestion keeps refreshing.
        #expect(verdicts == [.none, .none, .suggest(divergedURL), .suggest(divergedURL)])
    }

    @Test("A target change restarts the divergence count")
    func targetChangeRestartsDivergenceCount() {
        var advisor = FeedRelocationAdvisor()

        let verdicts = [divergedURL, divergedURL, otherDivergedURL, otherDivergedURL, otherDivergedURL].map {
            advisor.recordRedirect(feedURLString: feedURLString, finalURL: $0)
        }

        #expect(verdicts == [.none, .none, .none, .none, .suggest(otherDivergedURL)])
    }

    @Test("A same-host redirect clears the count and reports a stale suggestion")
    func sameHostRedirectClearsCountAndReportsStaleSuggestion() {
        var advisor = FeedRelocationAdvisor()

        let verdicts = [divergedURL, divergedURL, sameHostURL, divergedURL, divergedURL].map {
            advisor.recordRedirect(feedURLString: feedURLString, finalURL: $0)
        }

        // The counter restarted after the same-host redirect: two more
        // divergences are not enough to suggest again.
        #expect(verdicts == [.none, .none, .clearSuggestion, .none, .none])
    }

    @Test("Missing or hostless URLs are inert")
    func missingOrHostlessURLsAreInert() {
        var advisor = FeedRelocationAdvisor()

        let missingFinalURL = advisor.recordRedirect(feedURLString: feedURLString, finalURL: nil)
        let hostlessFeedURL = advisor.recordRedirect(feedURLString: "not a url", finalURL: divergedURL)
        let hostlessFinalURL = advisor.recordRedirect(
            feedURLString: feedURLString,
            finalURL: URL(string: "relative-path")!
        )

        #expect(missingFinalURL == .none)
        #expect(hostlessFeedURL == .none)
        #expect(hostlessFinalURL == .none)
    }

    @Test("Explicit divergence clears restart the count")
    func explicitDivergenceClearsRestartCount() {
        var advisor = FeedRelocationAdvisor()

        _ = advisor.recordRedirect(feedURLString: feedURLString, finalURL: divergedURL)
        _ = advisor.recordRedirect(feedURLString: feedURLString, finalURL: divergedURL)
        advisor.clearDivergence(feedURLString)
        let verdictAfterClear = advisor.recordRedirect(feedURLString: feedURLString, finalURL: divergedURL)

        #expect(verdictAfterClear == .none)
    }

    @Test("The https upgrade probe marks each feed exactly once")
    func httpsUpgradeProbeMarksEachFeedExactlyOnce() {
        var advisor = FeedRelocationAdvisor()
        let httpFeedURLString = "http://plain.example.com/feed.xml"
        let otherHTTPFeedURLString = "http://other.example.com/feed.xml"

        let firstProbe = advisor.shouldProbeHTTPSUpgrade(httpFeedURLString)
        let repeatProbe = advisor.shouldProbeHTTPSUpgrade(httpFeedURLString)
        let otherFeedProbe = advisor.shouldProbeHTTPSUpgrade(otherHTTPFeedURLString)

        #expect(firstProbe)
        #expect(!repeatProbe)
        #expect(otherFeedProbe)
    }
}
