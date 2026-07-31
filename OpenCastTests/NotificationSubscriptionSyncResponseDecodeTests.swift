import Foundation
import Testing
@testable import OpenCast

@Suite("Notification subscription sync response decoding")
struct NotificationSubscriptionSyncResponseDecodeTests {
    @Test("Decodes the pending lane from a new server response")
    func decodesPendingLaneFromNewServerResponse() throws {
        let body = Data("""
        {
          "message": "synced",
          "accepted": [
            {"feed_url": "https://example.com/known.xml", "title": "Known Show"}
          ],
          "rejected": [
            {"feed_url": "https://example.com/bad.xml", "error": "invalid_feed_url"}
          ],
          "pending": [
            {"feed_url": "https://example.com/new.xml"}
          ]
        }
        """.utf8)

        let response = try JSONDecoder().decode(NotificationSubscriptionSyncResponse.self, from: body)

        #expect(response.message == "synced")
        #expect(response.accepted.map(\.feedURL) == ["https://example.com/known.xml"])
        #expect(response.rejected.map(\.error) == ["invalid_feed_url"])
        #expect(response.pending.map(\.feedURL) == ["https://example.com/new.xml"])
    }

    @Test("Tolerates an old server response without the pending lane")
    func toleratesOldServerResponseWithoutPending() throws {
        let body = Data("""
        {
          "message": "synced",
          "accepted": [
            {"feed_url": "https://example.com/known.xml", "title": null}
          ],
          "rejected": []
        }
        """.utf8)

        let response = try JSONDecoder().decode(NotificationSubscriptionSyncResponse.self, from: body)

        #expect(response.accepted.count == 1)
        #expect(response.pending.isEmpty)
    }
}
