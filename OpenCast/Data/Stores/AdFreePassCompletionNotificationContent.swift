/// Copy for the queue-terminal completion notification. `nil` means the
/// terminal never notifies: a drained queue reports results, and an
/// interrupt explains the pause — the system posts an unsuppressable "Task
/// failed" banner when it revokes the continued-processing task, so this is
/// the honest counterpart telling the user nothing is lost. Cap deferral
/// and model consent stay silent (the queue screen carries those).
struct AdFreePassCompletionNotificationContent: Equatable {
    let title: String
    let body: String

    init?(terminal: AdFreePassQueueTerminalOutcome, outcomes: [AdFreePassQueueItemOutcome]) {
        if case .interrupted = terminal {
            title = "Ad detection paused"
            body = "iOS paused background processing. It will pick up where it left off next time you open OpenCast."
            return
        }

        guard case .drained = terminal else {
            return nil
        }

        var completed: [(episodeTitle: String, zoneCount: Int)] = []
        var failedCount = 0
        for outcome in outcomes {
            switch outcome.kind {
            case .completed(let zoneCount):
                completed.append((outcome.episodeTitle, zoneCount))
            case .failed:
                failedCount += 1
            }
        }

        guard completed.count + failedCount > 0 else {
            return nil
        }

        if completed.count == 1, failedCount == 0 {
            title = Self.foundTitle(zoneCount: completed[0].zoneCount, scope: completed[0].episodeTitle)
            body = ""
        } else if completed.isEmpty {
            title = "Ad detection finished"
            body = Self.failureLine(failedCount: failedCount)
        } else {
            let totalZoneCount = completed.reduce(0) { $0 + $1.zoneCount }
            title = Self.foundTitle(zoneCount: totalZoneCount, scope: Self.episodesPhrase(completed.count))
            body = failedCount > 0 ? Self.failureLine(failedCount: failedCount) : ""
        }
    }

    private static func foundTitle(zoneCount: Int, scope: String) -> String {
        guard zoneCount > 0 else {
            return "No ad breaks found in \(scope)"
        }

        let adBreaks = zoneCount == 1 ? "1 ad break" : "\(zoneCount) ad breaks"
        return "Found \(adBreaks) in \(scope)"
    }

    private static func episodesPhrase(_ count: Int) -> String {
        count == 1 ? "1 episode" : "\(count) episodes"
    }

    private static func failureLine(failedCount: Int) -> String {
        failedCount == 1
            ? "1 episode couldn't be analyzed."
            : "\(failedCount) episodes couldn't be analyzed."
    }
}
