import Testing
@testable import OpenCast

@MainActor
@Suite("Ad-free pass completion notification content")
struct AdFreePassCompletionNotificationContentTests {
    @Test("Deferred and consent terminals stay silent")
    func silentTerminalsNeverNotify() {
        let outcomes = [completedOutcome(episodeID: "a", zoneCount: 2)]
        for terminal in [AdFreePassQueueTerminalOutcome.capDeferred, .awaitingConsent] {
            #expect(
                AdFreePassCompletionNotificationContent(terminal: terminal, outcomes: outcomes) == nil,
                "terminal \(terminal)"
            )
        }

        #expect(
            AdFreePassCompletionNotificationContent(
                terminal: .drained(completedCount: 0, failedCount: 0),
                outcomes: []
            ) == nil
        )
    }

    @Test("Interrupts explain the pause instead of staying silent")
    func interruptedTerminalNotifiesPause() throws {
        let content = try #require(AdFreePassCompletionNotificationContent(
            terminal: .interrupted,
            outcomes: []
        ))
        #expect(content.title == "Ad detection paused")
        #expect(content.body.contains("pick up where it left off"))
    }

    @Test("Single episode copy inflects the zone count")
    func singleEpisodeCopy() throws {
        let zero = try #require(makeContent(outcomes: [
            completedOutcome(episodeID: "a", zoneCount: 0, title: "Episode Zero")
        ]))
        #expect(zero.title == "No ad breaks found in Episode Zero")
        #expect(zero.body.isEmpty)

        let one = try #require(makeContent(outcomes: [
            completedOutcome(episodeID: "a", zoneCount: 1, title: "Episode One")
        ]))
        #expect(one.title == "Found 1 ad break in Episode One")
        #expect(one.body.isEmpty)

        let many = try #require(makeContent(outcomes: [
            completedOutcome(episodeID: "a", zoneCount: 4, title: "Episode Many")
        ]))
        #expect(many.title == "Found 4 ad breaks in Episode Many")
        #expect(many.body.isEmpty)
    }

    @Test("Batch copy totals the zones and counts analyzed episodes")
    func batchCopy() throws {
        let batch = try #require(makeContent(outcomes: [
            completedOutcome(episodeID: "a", zoneCount: 4),
            completedOutcome(episodeID: "b", zoneCount: 3),
        ]))
        #expect(batch.title == "Found 7 ad breaks in 2 episodes")
        #expect(batch.body.isEmpty)

        let batchWithoutZones = try #require(makeContent(outcomes: [
            completedOutcome(episodeID: "a", zoneCount: 0),
            completedOutcome(episodeID: "b", zoneCount: 0),
        ]))
        #expect(batchWithoutZones.title == "No ad breaks found in 2 episodes")
    }

    @Test("Failures land in the body and inflect")
    func failureCopy() throws {
        let mixed = try #require(makeContent(outcomes: [
            completedOutcome(episodeID: "a", zoneCount: 3),
            failedOutcome(episodeID: "b"),
        ]))
        #expect(mixed.title == "Found 3 ad breaks in 1 episode")
        #expect(mixed.body == "1 episode couldn't be analyzed.")

        let allFailed = try #require(makeContent(outcomes: [
            failedOutcome(episodeID: "a"),
            failedOutcome(episodeID: "b"),
        ]))
        #expect(allFailed.title == "Ad detection finished")
        #expect(allFailed.body == "2 episodes couldn't be analyzed.")
    }

    // MARK: - Fixtures

    private func makeContent(
        outcomes: [AdFreePassQueueItemOutcome]
    ) -> AdFreePassCompletionNotificationContent? {
        var completedCount = 0
        var failedCount = 0
        for outcome in outcomes {
            switch outcome.kind {
            case .completed:
                completedCount += 1
            case .failed, .cloudUnavailable:
                failedCount += 1
            }
        }
        return AdFreePassCompletionNotificationContent(
            terminal: .drained(completedCount: completedCount, failedCount: failedCount),
            outcomes: outcomes
        )
    }

    private func completedOutcome(
        episodeID: String,
        zoneCount: Int,
        title: String? = nil
    ) -> AdFreePassQueueItemOutcome {
        AdFreePassQueueItemOutcome(
            episodeID: episodeID,
            episodeTitle: title ?? "Episode \(episodeID)",
            artworkURL: nil,
            kind: .completed(zoneCount: zoneCount)
        )
    }

    private func failedOutcome(episodeID: String) -> AdFreePassQueueItemOutcome {
        AdFreePassQueueItemOutcome(
            episodeID: episodeID,
            episodeTitle: "Episode \(episodeID)",
            artworkURL: nil,
            kind: .failed(message: "Download failed.")
        )
    }
}
