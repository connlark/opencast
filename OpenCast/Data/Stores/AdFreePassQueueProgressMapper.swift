import Foundation

/// Composite queue progress over the per-episode mapper: units are
/// `floor(1000 × (finishedItems + perEpisodeUnits/1000) / totalItems)`,
/// monotonic-clamped at the composite level so appending items mid-run
/// holds progress flat instead of running backwards. For a queue of one
/// the composite equals the per-episode mapper exactly.
struct AdFreePassQueueProgressMapper: Equatable {
    private var episodeMapper: EpisodeAdFreePassProgressMapper
    private var finishedItemCount = 0
    private var totalItemCount = 1
    private(set) var completedUnitCount: Int64 = 0

    /// `subunitsPerUnit` refines the 0...1000 scale, as the per-episode
    /// mapper does.
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

        let episodeUnits = episodeMapper.update(for: stage, stageElapsed: stageElapsed)
        completedUnitCount = max(completedUnitCount, min(composite(episodeUnits), totalUnitCount))
        return completedUnitCount
    }

    /// One creep tick: `update`, and an analyzing step also moves at least
    /// one unit of this scale, never past one unit short of its slice end.
    mutating func tick(
        for stage: EpisodeAdFreePassStage,
        queueContext: AdFreePassQueueContext,
        stageElapsed: TimeInterval
    ) -> Int64 {
        let units = update(for: stage, queueContext: queueContext, stageElapsed: stageElapsed)
        guard let sliceCeiling = EpisodeAdFreePassProgressMapper.creepCeiling(
            for: stage,
            subunitsPerUnit: episodeMapper.subunitsPerUnit
        ) else {
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

    private func composite(_ episodeUnits: Int64) -> Int64 {
        (Int64(finishedItemCount) * totalUnitCount + episodeUnits) / Int64(totalItemCount)
    }
}
