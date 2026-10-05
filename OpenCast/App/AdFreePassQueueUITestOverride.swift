import Foundation

/// UI-testing stand-in for the live ad-detection queue so the pipeline card,
/// the Ad Detection screen, and the Inbox indicator can show a pass mid-flight
/// without running one.
///
/// `OPENCAST_UI_TEST_AD_FREE_PASS_QUEUE_OVERRIDE=<stage>:<activeEpisodeID>[|<pendingEpisodeID>…]`
/// with `<stage>` one of `downloading`, `transcribing`, `analyzing`, or the
/// cloud pass's `uploading` (this device's audio, held mid-upload) and
/// `cloudtranscribing`. The transcribing stage reads
/// `OPENCAST_UI_TEST_AD_FREE_PASS_QUEUE_OVERRIDE_PROGRESS=<completedSeconds>/<totalSeconds>`;
/// the uploading stage reads the same key as `<completedParts>/<totalParts>`.
struct AdFreePassQueueUITestOverride: Equatable {
    static let environmentKey = "OPENCAST_UI_TEST_AD_FREE_PASS_QUEUE_OVERRIDE"
    static let progressEnvironmentKey = "OPENCAST_UI_TEST_AD_FREE_PASS_QUEUE_OVERRIDE_PROGRESS"

    var activeEpisodeID: String
    var pendingEpisodeIDs: [String]
    var stage: EpisodeAdFreePassStage

    static func resolve(environment: [String: String]) -> AdFreePassQueueUITestOverride? {
        guard let rawValue = environment[environmentKey]?.trimmedNonEmpty else {
            return nil
        }

        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return nil
        }

        let episodeIDs = parts[1].split(separator: "|").map(String.init).filter { !$0.isEmpty }
        guard let activeEpisodeID = episodeIDs.first else {
            return nil
        }

        let stage: EpisodeAdFreePassStage
        switch parts[0].lowercased() {
        case "downloading":
            stage = .downloadingEpisode
        case "transcribing":
            stage = .transcribing(progress(environment: environment))
        case "analyzing":
            stage = .analyzing
        case "uploading":
            let (completedParts, totalParts) = uploadParts(environment: environment)
            stage = .cloudUploadingExactCopy(completedParts: completedParts, totalParts: totalParts)
        case "cloudtranscribing":
            stage = .cloudTranscribing(nil)
        default:
            return nil
        }

        return AdFreePassQueueUITestOverride(
            activeEpisodeID: activeEpisodeID,
            pendingEpisodeIDs: Array(episodeIDs.dropFirst()),
            stage: stage
        )
    }

    private static func uploadParts(environment: [String: String]) -> (completed: Int, total: Int) {
        let parts = environment[progressEnvironmentKey]?.split(separator: "/").compactMap { Int($0) } ?? []
        guard parts.count == 2 else {
            return (2, 10)
        }
        return (parts[0], parts[1])
    }

    private static func progress(environment: [String: String]) -> EpisodeTranscriptionProgress {
        var completed: TimeInterval = 64
        var total: TimeInterval = 180
        if let rawValue = environment[progressEnvironmentKey] {
            let parts = rawValue.split(separator: "/").compactMap { TimeInterval($0) }
            if parts.count == 2, parts[1] > 0 {
                completed = parts[0]
                total = parts[1]
            }
        }
        return EpisodeTranscriptionProgress(
            audioDuration: total,
            completedDuration: completed,
            checkpointCount: 0,
            currentWindowIndex: nil,
            currentText: nil
        )
    }
}
