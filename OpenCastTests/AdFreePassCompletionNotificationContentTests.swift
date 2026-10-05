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

    @Test("On-device interrupts keep the device-paused copy")
    func interruptedTerminalNotifiesPause() throws {
        let content = try #require(AdFreePassCompletionNotificationContent(
            terminal: .interrupted,
            outcomes: []
        ))
        #expect(content.title == "Ad detection paused")
        #expect(content.body == "iOS paused background processing. It will pick up where it left off next time you open OpenCast.")
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

    @Test("A mixed drain summarizes only the locally owned outcomes")
    func mixedDrainSummarizesLocalOutcomes() throws {
        let completedLocally = try #require(AdFreePassCompletionNotificationContent(
            terminal: .drained(completedCount: 2, failedCount: 1),
            outcomes: [
                completedOutcome(episodeID: "a", zoneCount: 3, title: "Local Episode"),
                completedOutcome(episodeID: "b", zoneCount: 5, owner: .remote),
                failedOutcome(episodeID: "c", owner: .remote),
            ]
        ))
        #expect(completedLocally.title == "Found 3 ad breaks in Local Episode")
        #expect(completedLocally.body.isEmpty)

        let failedLocally = try #require(AdFreePassCompletionNotificationContent(
            terminal: .drained(completedCount: 1, failedCount: 1),
            outcomes: [
                completedOutcome(episodeID: "a", zoneCount: 2, owner: .remote),
                failedOutcome(episodeID: "b"),
            ]
        ))
        #expect(failedLocally.title == "Ad detection finished")
        #expect(failedLocally.body == "1 episode couldn't be analyzed.")
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
        title: String? = nil,
        owner: JobCompletionDeliveryOwner = .local
    ) -> AdFreePassQueueItemOutcome {
        AdFreePassQueueItemOutcome(
            episodeID: episodeID,
            episodeTitle: title ?? "Episode \(episodeID)",
            artworkURL: nil,
            kind: .completed(zoneCount: zoneCount),
            completionDeliveryOwner: owner
        )
    }

    private func failedOutcome(
        episodeID: String,
        owner: JobCompletionDeliveryOwner = .local
    ) -> AdFreePassQueueItemOutcome {
        AdFreePassQueueItemOutcome(
            episodeID: episodeID,
            episodeTitle: "Episode \(episodeID)",
            artworkURL: nil,
            kind: .failed(message: "Download failed."),
            completionDeliveryOwner: owner
        )
    }
}
