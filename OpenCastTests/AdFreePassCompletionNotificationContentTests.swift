import Testing
@testable import OpenCast

@MainActor
@Suite("Ad-free pass completion notification content")
struct AdFreePassCompletionNotificationContentTests {
    @Test("The consent terminal stays silent")
    func silentTerminalsNeverNotify() {
        let outcomes = [completedOutcome(episodeID: "a", zoneCount: 2)]
        for terminal in [AdFreePassQueueTerminalOutcome.awaitingConsent] {
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

    @Test("An expiration park of a cloud item says the server is still working, never that the device paused")
    func cloudParkSaysServerIsStillWorking() throws {
        let content = try #require(AdFreePassCompletionNotificationContent(
            terminal: .remoteParked(.parked),
            outcomes: [completedOutcome(episodeID: "a", zoneCount: 2)]
        ))

        #expect(content.title == RemoteTranscriptionStatusPresentation.parkedTitle)
        #expect(content.title == "Still running on the server")
        #expect(content.body == RemoteTranscriptionStatusPresentation.parkedDetail(for: .parked))
        #expect(content.title != "Ad detection paused")
        #expect(!content.body.contains("iOS paused"))
    }

    @Test("Connection-loss and local-failure parks and a cloud user cancel stay silent")
    func silentCloudTerminals() {
        for terminal in [
            AdFreePassQueueTerminalOutcome.remoteParked(.connectionLost),
            .remoteParked(.localRequestFailed),
            .cloudUserCancelled,
        ] {
            #expect(
                AdFreePassCompletionNotificationContent(terminal: terminal, outcomes: []) == nil,
                "terminal \(terminal)"
            )
        }
    }

    @Test("An all-remote drain is silent: a remote owner delivers those completions")
    func allRemoteDrainIsSilent() {
        let outcomes = [
            completedOutcome(episodeID: "a", zoneCount: 4, owner: .remote),
            failedOutcome(episodeID: "b", owner: .remote),
        ]

        #expect(AdFreePassCompletionNotificationContent(
            terminal: .drained(completedCount: 1, failedCount: 1),
            outcomes: outcomes
        ) == nil)
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

        let keyRequired = try #require(makeContent(outcomes: [
            completedOutcome(episodeID: "a", zoneCount: 3),
            AdFreePassQueueItemOutcome(
                episodeID: "b",
                episodeTitle: "Episode b",
                artworkURL: nil,
                kind: .keyRequired(.noKey),
                completionDeliveryOwner: .local
            ),
        ]))
        #expect(keyRequired.body == "1 episode couldn't be analyzed.")
    }

    @Test("A drain of new episodes' items alone posts nothing; a mixed drain counts only the others")
    func preparedOutcomesStayOutOfTheSummary() throws {
        #expect(makeContent(outcomes: [
            completedOutcome(episodeID: "a", zoneCount: 2, origin: .prepared),
            failedOutcome(episodeID: "b", origin: .prepared),
        ]) == nil)

        let mixed = try #require(makeContent(outcomes: [
            completedOutcome(episodeID: "a", zoneCount: 2, origin: .prepared),
            completedOutcome(episodeID: "b", zoneCount: 3, origin: .auto),
            failedOutcome(episodeID: "c", origin: .prepared),
            failedOutcome(episodeID: "d"),
        ]))
        #expect(mixed.title == "Found 3 ad breaks in 1 episode")
        #expect(mixed.body == "1 episode couldn't be analyzed.")
    }

    @Test("A pause that holds an unattended item to resume by itself posts nothing; any other pause posts as before")
    func heldUnattendedPauseIsSilent() throws {
        #expect(AdFreePassCompletionNotificationContent(
            terminal: .interrupted,
            outcomes: [],
            isHoldingUnattendedItem: true
        ) == nil)

        let manual = try #require(AdFreePassCompletionNotificationContent(
            terminal: .interrupted,
            outcomes: [],
            isHoldingUnattendedItem: false
        ))
        #expect(manual.title == "Ad detection paused")
        #expect(AdFreePassCompletionNotificationContent(
            terminal: .drained(completedCount: 1, failedCount: 0),
            outcomes: [completedOutcome(episodeID: "a", zoneCount: 1)],
            isHoldingUnattendedItem: true
        ) != nil)
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
            case .failed, .cloudUnavailable, .keyRequired:
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
        owner: JobCompletionDeliveryOwner = .local,
        origin: AdFreePassQueueOrigin = .manual
    ) -> AdFreePassQueueItemOutcome {
        AdFreePassQueueItemOutcome(
            episodeID: episodeID,
            episodeTitle: "Episode \(episodeID)",
            artworkURL: nil,
            kind: .completed(zoneCount: zoneCount),
            completionDeliveryOwner: owner,
            origin: origin
        )
    }

    private func failedOutcome(
        episodeID: String,
        owner: JobCompletionDeliveryOwner = .local,
        origin: AdFreePassQueueOrigin = .manual
    ) -> AdFreePassQueueItemOutcome {
        AdFreePassQueueItemOutcome(
            episodeID: episodeID,
            episodeTitle: "Episode \(episodeID)",
            artworkURL: nil,
            kind: .failed(message: "Download failed."),
            completionDeliveryOwner: owner,
            origin: origin
        )
    }
}
