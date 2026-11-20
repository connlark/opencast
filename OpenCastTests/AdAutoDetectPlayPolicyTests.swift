import Testing
@testable import OpenCast

@MainActor
@Suite("Auto-detect play policy")
struct AdAutoDetectPlayPolicyTests {
    @Test(
        "Play qualifies for an auto pass only when opted in, without an attached current analysis, and out of the queue",
        arguments: [
            (AdFreePassQueueEpisodeStatus.notQueued, true, false, true, true),
            (.notQueued, false, false, true, false),
            (.notQueued, true, true, true, false),
            (.notQueued, true, true, false, true),
            (.completed(zoneCount: 2), true, false, true, true),
            (.queued(ahead: 0), true, false, false, false),
            (.running, true, false, true, false),
            (.remoteParked(.connectionLost), true, false, true, false),
            (.failed(message: "probe"), true, false, true, false),
            (.cloudUnavailable(message: "No credits."), true, false, true, false),
            (.keyRequired(.noKey), true, false, false, false)
        ]
    )
    func playQualificationTable(
        status: AdFreePassQueueEpisodeStatus,
        isEnabled: Bool,
        isCurrent: Bool,
        isAttached: Bool,
        expected: Bool
    ) {
        let policy = AdAutoDetectPlayPolicy(
            isAutoDetectEnabled: isEnabled,
            hasCurrentCompletedAnalysis: isCurrent,
            isAnalysisAttached: isAttached,
            queueStatus: status
        )
        #expect(policy.shouldEnqueue == expected)
    }

    @Test(
        "A play reaches the policy only with no retained outcome or a completed one; a failure this session is not retried on play",
        arguments: [
            (AdFreePassQueueEpisodeStatus.notQueued, true),
            (.completed(zoneCount: 1), true),
            (.failed(message: "probe"), false),
            (.cloudUnavailable(message: "No credits."), false),
            (.keyRequired(.noKey), false),
            (.queued(ahead: 0), false),
            (.running, false),
            (.remoteParked(.parked), false)
        ]
    )
    func playAdmission(status: AdFreePassQueueEpisodeStatus, admitted: Bool) {
        #expect(AdAutoDetectPlayPolicy.admitsPlay(with: status) == admitted)
    }
}
