import Foundation

/// Composite queue progress over the per-episode mapper: units are
/// `floor(1000 × (finishedItems + perEpisodeUnits/1000) / totalItems)`,
/// monotonic-clamped at the composite level so appending items mid-run
/// holds progress flat instead of running backwards. For a queue of one
/// the composite equals the per-episode mapper exactly.
struct AdFreePassQueueProgressMapper: Equatable {
    static let totalUnitCount = EpisodeAdFreePassProgressMapper.totalUnitCount

    private var episodeMapper = EpisodeAdFreePassProgressMapper()
    private var finishedItemCount = 0
    private var totalItemCount = 1
    private(set) var completedUnitCount: Int64 = 0

    var fractionCompleted: Double {
        Double(completedUnitCount) / Double(Self.totalUnitCount)
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
        let compositeUnits = (Int64(finishedItemCount) * Self.totalUnitCount + episodeUnits) / Int64(totalItemCount)
        completedUnitCount = max(completedUnitCount, min(compositeUnits, Self.totalUnitCount))
        return completedUnitCount
    }

    mutating func markDrained() -> Int64 {
        completedUnitCount = Self.totalUnitCount
        return completedUnitCount
    }

    mutating func reset() {
        episodeMapper.reset()
        finishedItemCount = 0
        totalItemCount = 1
        completedUnitCount = 0
    }
}
