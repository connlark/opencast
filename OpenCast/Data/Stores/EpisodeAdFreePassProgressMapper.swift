import Foundation
import OpenCastTranscription

struct EpisodeAdFreePassProgressMapper: Equatable {
    static let totalUnitCount: Int64 = 1_000

    private(set) var completedUnitCount: Int64 = 0

    mutating func update(
        for stage: EpisodeAdFreePassStage,
        stageElapsed: TimeInterval = 0
    ) -> Int64 {
        let mappedUnits = Self.units(for: stage, stageElapsed: stageElapsed, currentUnits: completedUnitCount)
        completedUnitCount = max(completedUnitCount, mappedUnits)
        return completedUnitCount
    }

    mutating func reset() {
        completedUnitCount = 0
    }

    static func units(
        for stage: EpisodeAdFreePassStage,
        stageElapsed: TimeInterval = 0,
        currentUnits: Int64 = 0
    ) -> Int64 {
        switch stage {
        case .idle:
            0
        case .downloadingEpisode:
            min(140, 20 + creepUnits(stageElapsed: stageElapsed))
        case .awaitingModelDownloadConsent:
            currentUnits
        case .installingModel(let progress):
            150 + Int64((installFraction(progress) * 100).rounded(.down))
        case .installingSpeechAssets(let fractionCompleted):
            150 + Int64((min(max(fractionCompleted, 0), 1) * 100).rounded(.down))
        case .transcribing(let progress):
            // Creep through checkpoint droughts (throttled background
            // transcription can stretch real checkpoints past the ~60 s
            // stalled-progress window after which the system expires the
            // task); capped below the analyzing band.
            min(
                900,
                250 + Int64(((progress.fractionCompleted ?? 0) * 650).rounded(.down))
                    + creepUnits(stageElapsed: stageElapsed)
            )
        case .analyzing:
            min(975, 910 + creepUnits(stageElapsed: stageElapsed))
        case .cloudQueued:
            min(250, 20 + creepUnits(stageElapsed: stageElapsed))
        case .cloudTranscribing(let progress):
            min(
                900,
                250 + Int64(((progress?.fractionCompleted ?? 0) * 650).rounded(.down))
                    + creepUnits(stageElapsed: stageElapsed)
            )
        case .cloudDetectingAds:
            min(975, 910 + creepUnits(stageElapsed: stageElapsed))
        case .completed:
            1_000
        case .failed, .unavailable, .interrupted, .cloudUnavailable:
            currentUnits
        }
    }

    private static func creepUnits(stageElapsed: TimeInterval) -> Int64 {
        max(0, Int64(stageElapsed / 2))
    }

    private static func installFraction(_ progress: OpenCastWhisperModelInstallProgress) -> Double {
        guard progress.totalByteCount > 0 else {
            return 0
        }
        return min(max(Double(progress.completedByteCount) / Double(progress.totalByteCount), 0), 1)
    }
}
