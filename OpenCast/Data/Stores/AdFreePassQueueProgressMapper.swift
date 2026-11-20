import Foundation

/// Clamped monotonic, so items appended mid-run hold progress flat instead of running it backwards.
struct AdFreePassQueueProgressMapper: Equatable {
    private var episodeMapper: EpisodeAdFreePassProgressMapper
    private var finishedItemCount = 0
    private var totalItemCount = 1
    private(set) var completedUnitCount: Int64 = 0

    init(subunitsPerUnit: Int64 = 1) {
        episodeMapper = EpisodeAdFreePassProgressMapper(subunitsPerUnit: subunitsPerUnit)
    }

    /// The scale's total: 1000 times `subunitsPerUnit`.
    var totalUnitCount: Int64 {
        episodeMapper.scaledUnitCount
    }

    var fractionCompleted: Double {
        Double(completedUnitCount) / Double(totalUnitCount)
    }

    mutating func update(
        for stage: EpisodeAdFreePassStage,
        queueContext: AdFreePassQueueContext,
        stageElapsed: TimeInterval = 0
    ) -> Int64 {
        if queueContext.finishedItemCount != finishedItemCount {
            episodeMapper.reset()
        }
        finishedItemCount = queueContext.finishedItemCount
        totalItemCount = max(queueContext.totalItemCount, 1)

        episodeMapper.noteAttempt(of: stage, position: episodePosition)
        let episodeUnits = episodeMapper.update(for: stage, stageElapsed: stageElapsed)
        completedUnitCount = max(completedUnitCount, min(composite(episodeUnits), totalUnitCount))
        return completedUnitCount
    }

    mutating func tick(
        for stage: EpisodeAdFreePassStage,
        queueContext: AdFreePassQueueContext,
        stageElapsed: TimeInterval
    ) -> Int64 {
        let units = update(for: stage, queueContext: queueContext, stageElapsed: stageElapsed)
        guard let sliceCeiling = episodeMapper.creepCeiling(for: stage) else {
            return units
        }
        completedUnitCount = max(units, min(units + 1, composite(sliceCeiling)))
        return completedUnitCount
    }

    mutating func markDrained() -> Int64 {
        completedUnitCount = totalUnitCount
        return completedUnitCount
    }

    mutating func reset() {
        episodeMapper.reset()
        finishedItemCount = 0
        totalItemCount = 1
        completedUnitCount = 0
    }

    /// Derived from `completedUnitCount`: creep moves this mapper alone, so a handover based on
    /// the episode mapper's own position could not move this one at all.
    private var episodePosition: Int64 {
        let position = completedUnitCount * Int64(totalItemCount) - Int64(finishedItemCount) * totalUnitCount
        return min(max(position, episodeMapper.completedUnitCount), totalUnitCount)
    }

    private func composite(_ episodeUnits: Int64) -> Int64 {
        (Int64(finishedItemCount) * totalUnitCount + episodeUnits) / Int64(totalItemCount)
    }
}
