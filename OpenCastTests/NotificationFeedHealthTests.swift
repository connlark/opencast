import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Notification feed health")
struct NotificationFeedHealthTests {
    @Test("Decodes an accepted subscription carrying health")
    func decodesAcceptedSubscriptionWithHealth() throws {
        let json = Data(
            """
            {
              "message": "ok",
              "accepted": [
                {
                  "feed_url": "https://example.com/feed.xml",
                  "title": "Show",
                  "health": {
                    "consecutive_failures": 4,
                    "last_http_status": 503,
                    "last_error": "http_error",
                    "last_polled_at": 1780000000
                  }
                }
              ],
              "rejected": [],
              "pending": []
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(NotificationSubscriptionSyncResponse.self, from: json)
        let health = try #require(response.accepted.first?.health)

        #expect(health.consecutiveFailures == 4)
        #expect(health.lastHTTPStatus == 503)
        #expect(health.lastError == "http_error")
        #expect(health.lastPolledAt == Date(timeIntervalSince1970: 1_780_000_000))
        #expect(health.isDegraded)
    }

    @Test("Decodes old-server responses without health as no data")
    func decodesOldServerResponsesWithoutHealth() throws {
        let json = Data(
            """
            {
              "message": "ok",
              "accepted": [
                { "feed_url": "https://example.com/feed.xml", "title": "Show" }
              ],
              "rejected": []
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(NotificationSubscriptionSyncResponse.self, from: json)

        #expect(response.accepted.first?.health == nil)
        #expect(response.pending.isEmpty)
    }

    @Test("Health with sparse fields decodes and stays below the threshold")
    func sparseHealthDecodesBelowThreshold() throws {
        let json = Data(
            """
            { "feed_url": "https://example.com/feed.xml", "health": { "consecutive_failures": 2 } }
            """.utf8
        )

        let accepted = try JSONDecoder().decode(NotificationSubscriptionSyncAccepted.self, from: json)
        let health = try #require(accepted.health)

        #expect(health.consecutiveFailures == 2)
        #expect(health.lastHTTPStatus == nil)
        #expect(health.lastPolledAt == nil)
        #expect(!health.isDegraded)
    }

    @Test("Health records round-trip through the local cache store wholesale")
    func healthRecordsRoundTripThroughLocalCache() async throws {
        let store = SQLiteLocalLibraryCacheStore.inMemory()
        let first = NotificationFeedHealthRecord(
            feedURL: "https://example.com/one.xml",
            health: NotificationFeedHealth(
                consecutiveFailures: 3,
                lastHTTPStatus: 500,
                lastError: "http_error",
                lastPolledAtEpochSeconds: 1_780_000_000
            )
        )
        let second = NotificationFeedHealthRecord(
            feedURL: "https://example.com/two.xml",
            health: NotificationFeedHealth(consecutiveFailures: 0)
        )
        try await store.replaceNotificationFeedHealth([first, second])

        let loaded = try await store.notificationFeedHealthByFeedURL()
        #expect(loaded.count == 2)
        #expect(loaded[first.feedURL] == first.health)
        #expect(loaded[second.feedURL] == second.health)

        // Wholesale replacement drops feeds absent from the newest sync.
        try await store.replaceNotificationFeedHealth([second])
        let replaced = try await store.notificationFeedHealthByFeedURL()
        #expect(replaced.count == 1)
        #expect(replaced[second.feedURL] == second.health)
    }
}
