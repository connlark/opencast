import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Feed health derivation")
struct FeedHealthStatusTests {
    static let feedURL = "https://example.com/health.xml"
    static let checkedAt = Date(timeIntervalSince1970: 1_775_736_000)
    static let succeededAt = Date(timeIntervalSince1970: 1_775_476_800)
    static let contentChangedAt = Date(timeIntervalSince1970: 1_775_390_400)

    @Test("A fresh feed with no logs reads as never refreshed")
    func freshFeedReadsAsNeverRefreshed() {
        let health = FeedHealthStatus.derive(latestLog: nil, latestSuccessAt: nil, contentChangedAt: nil)

        #expect(health.kind == .neverRefreshed)
        #expect(!health.isDegraded)
        #expect(health.statusLine == nil)
        #expect(health.checkedUpdatedLine == nil)
    }

    @Test("A successful latest log reads healthy with checked and updated recency")
    func successfulLatestLogReadsHealthy() {
        let health = FeedHealthStatus.derive(
            latestLog: makeLog(errorMessage: nil),
            latestSuccessAt: Self.checkedAt,
            contentChangedAt: Self.contentChangedAt
        )

        #expect(health.kind == .healthy)
        #expect(!health.isDegraded)
        #expect(health.statusLine == nil)
        #expect(health.lastCheckedAt == Self.checkedAt)
        #expect(health.lastContentChangeAt == Self.contentChangedAt)
        #expect(health.checkedUpdatedLine?.contains("Checked") == true)
        #expect(health.checkedUpdatedLine?.contains("Updated") == true)
    }

    @Test("A feed failing for days reads as hasn't-refreshed-since")
    func failingFeedReadsAsSince() {
        let health = FeedHealthStatus.derive(
            latestLog: makeLog(errorMessage: "The server returned HTTP 500."),
            latestSuccessAt: Self.succeededAt,
            contentChangedAt: Self.contentChangedAt
        )

        #expect(health.kind == .failingSince(Self.succeededAt))
        #expect(health.isDegraded)
        #expect(health.replacesRefreshedLine)
        #expect(health.statusLine?.hasPrefix("Hasn't refreshed since") == true)
    }

    @Test("A feed that never succeeded says so")
    func neverSucceededFeedSaysSo() {
        let health = FeedHealthStatus.derive(
            latestLog: makeLog(errorMessage: "This address did not return an RSS podcast feed."),
            latestSuccessAt: nil,
            contentChangedAt: nil
        )

        #expect(health.kind == .neverSucceeded)
        #expect(health.isDegraded)
        #expect(health.statusLine == "Refresh has never succeeded")
    }

    @Test("A partial salvage reads as partial, not failed")
    func partialSalvageReadsAsPartial() {
        let health = FeedHealthStatus.derive(
            latestLog: makeLog(errorMessage: RefreshLogSnapshot.partialFeedSalvageMessage),
            latestSuccessAt: Self.succeededAt,
            contentChangedAt: Self.contentChangedAt
        )

        #expect(health.kind == .partial)
        #expect(health.isDegraded)
        #expect(!health.replacesRefreshedLine)
        #expect(health.statusLine == "Partial feed loaded")
    }

    private func makeLog(errorMessage: String?) -> RefreshLogSnapshot {
        RefreshLogSnapshot(
            feedURL: Self.feedURL,
            startedAt: Self.checkedAt.addingTimeInterval(-5),
            finishedAt: Self.checkedAt,
            errorMessage: errorMessage
        )
    }
}
