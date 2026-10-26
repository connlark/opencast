import Foundation
import OpenCastTranscription

/// Maps pass stages onto a 0...1000 scale. `subunitsPerUnit` refines it
/// (the background card uses a finer scale so a slow analyzing step moves
/// on every creep tick); every band edge is the same scale point times it.
struct EpisodeAdFreePassProgressMapper: Equatable {
    static let totalUnitCount: Int64 = 1_000

    let subunitsPerUnit: Int64
    private(set) var completedUnitCount: Int64 = 0

    init(subunitsPerUnit: Int64 = 1) {
        self.subunitsPerUnit = max(subunitsPerUnit, 1)
    }

    var scaledUnitCount: Int64 {
        Self.totalUnitCount * subunitsPerUnit
    }

    mutating func update(
        for stage: EpisodeAdFreePassStage,
        stageElapsed: TimeInterval = 0
    ) -> Int64 {
        let mappedUnits = Self.units(
            for: stage,
            stageElapsed: stageElapsed,
            currentUnits: completedUnitCount,
            subunitsPerUnit: subunitsPerUnit
        )
        completedUnitCount = max(completedUnitCount, mappedUnits)
        return completedUnitCount
    }

    mutating func reset() {
        completedUnitCount = 0
    }

    /// `currentUnits` and the result are on the scale `subunitsPerUnit`
    /// sets. Holding stages return `currentUnits`.
    static func units(
        for stage: EpisodeAdFreePassStage,
        stageElapsed: TimeInterval = 0,
        currentUnits: Int64 = 0,
        subunitsPerUnit: Int64 = 1
    ) -> Int64 {
        let subunits = max(subunitsPerUnit, 1)
        switch stage {
        case .analyzing(let steps):
            return analyzingUnits(steps: steps, stageElapsed: stageElapsed, subunitsPerUnit: subunits)
        case .awaitingModelDownloadConsent, .failed, .unavailable, .interrupted, .cloudUnavailable, .cloudParked:
            return currentUnits
        default:
            return bandUnits(for: stage, stageElapsed: stageElapsed) * subunits
        }
    }

    /// The highest units an analyzing step's creep may reach: one unit (on
    /// the given scale) short of its slice end. `nil` for any other stage.
    static func creepCeiling(for stage: EpisodeAdFreePassStage, subunitsPerUnit: Int64 = 1) -> Int64? {
        guard case .analyzing(let steps) = stage else {
            return nil
        }
        let slice = analyzingSlice(steps: steps, subunitsPerUnit: max(subunitsPerUnit, 1))
        return slice.end.map { max(slice.start, $0 - 1) }
    }

    /// The 0...1000 point of every other stage; `units` maps analyzing and
    /// the holding stages itself.
    private static func bandUnits(
        for stage: EpisodeAdFreePassStage,
        stageElapsed: TimeInterval
    ) -> Int64 {
        switch stage {
        case .idle:
            0
        case .downloadingEpisode:
            min(140, 20 + creepUnits(stageElapsed: stageElapsed))
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
            analyzingBandStart
        case .cloudQueued, .cloudVerifying, .cloudUploadingExactCopy, .cloudWaitingForCredits:
            min(250, 20 + creepUnits(stageElapsed: stageElapsed))
        case .cloudTranscribing(let progress):
            min(
                900,
                250 + Int64(((progress?.fractionCompleted ?? 0) * 650).rounded(.down))
                    + creepUnits(stageElapsed: stageElapsed)
            )
        case .cloudFinishing:
            min(analyzingBandStart - 1, 900 + creepUnits(stageElapsed: stageElapsed))
        case .completed:
            1_000
        case .awaitingModelDownloadConsent, .failed, .unavailable, .interrupted, .cloudUnavailable, .cloudParked:
            0
        }
    }

    private static let analyzingBandStart: Int64 = 910
    private static let analyzingBandWidth: Int64 = 65

    /// Each step owns an equal slice of the analyzing band: a finished step
    /// opens the next slice. Within a slice the creep is paced over the
    /// step's time budget and stops one unit short of the slice end, so it
    /// cannot run out before the step could have timed out, and the band's
    /// end waits for the run's last step. A step the run adds later (a
    /// corrective request) narrows the slices; the mapper's clamp keeps
    /// units from going back.
    private static func analyzingUnits(
        steps: EpisodeAdFreePassAnalysisSteps?,
        stageElapsed: TimeInterval,
        subunitsPerUnit: Int64
    ) -> Int64 {
        let slice = analyzingSlice(steps: steps, subunitsPerUnit: subunitsPerUnit)
        guard let end = slice.end else {
            return slice.start
        }
        let room = max(0, end - 1 - slice.start)
        let budget = (steps ?? .unknownRun).stepBudgetSeconds
        let paced = min(max(stageElapsed / budget, 0), 1)
        return slice.start + Int64((Double(room) * paced).rounded(.down))
    }

    /// The current step's slice; no end once every step is answered.
    private static func analyzingSlice(
        steps: EpisodeAdFreePassAnalysisSteps?,
        subunitsPerUnit: Int64
    ) -> (start: Int64, end: Int64?) {
        let steps = steps ?? .unknownRun
        let total = Int64(steps.total)
        let completed = Int64(steps.completed)
        let bandStart = analyzingBandStart * subunitsPerUnit
        let bandWidth = analyzingBandWidth * subunitsPerUnit
        let start = bandStart + bandWidth * completed / total
        guard completed < total else {
            return (start, nil)
        }
        return (start, bandStart + bandWidth * (completed + 1) / total)
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
