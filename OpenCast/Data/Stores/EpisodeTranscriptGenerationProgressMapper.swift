import Foundation

/// Maps generate-transcript request phases onto the 0–1000 continued
/// processing progress band, monotonic-clamped like
/// `EpisodeAdFreePassProgressMapper` so pulled fractions and creep can never
/// run the system card backwards.
struct EpisodeTranscriptGenerationProgressMapper: Equatable {
    static let totalUnitCount: Int64 = 1_000

    private(set) var completedUnitCount: Int64 = 0

    mutating func update(
        for phase: EpisodeTranscriptionRequestPhase,
        installFraction: Double? = nil,
        transcriptionFraction: Double? = nil,
        stageElapsed: TimeInterval = 0
    ) -> Int64 {
        let mappedUnits = Self.units(
            for: phase,
            installFraction: installFraction,
            transcriptionFraction: transcriptionFraction,
            stageElapsed: stageElapsed,
            currentUnits: completedUnitCount
        )
        completedUnitCount = max(completedUnitCount, mappedUnits)
        return completedUnitCount
    }

    mutating func reset() {
        completedUnitCount = 0
    }

    static func units(
        for phase: EpisodeTranscriptionRequestPhase,
        installFraction: Double? = nil,
        transcriptionFraction: Double? = nil,
        stageElapsed: TimeInterval = 0,
        currentUnits: Int64 = 0
    ) -> Int64 {
        switch phase {
        case .downloading:
            min(140, 20 + creepUnits(stageElapsed: stageElapsed))
        case .preparingWhisper:
            min(250, 150 + Int64((clamped(installFraction) * 100).rounded(.down)))
        case .transcribingWhisper, .transcribingAppleSpeech:
            // Creep through checkpoint droughts so throttled background
            // transcription never trips the stalled-progress expiration.
            min(
                975,
                250 + Int64((clamped(transcriptionFraction) * 700).rounded(.down))
                    + creepUnits(stageElapsed: stageElapsed)
            )
        case .completed:
            1_000
        case .interrupted, .cancelled, .failed:
            currentUnits
        }
    }

    private static func creepUnits(stageElapsed: TimeInterval) -> Int64 {
        max(0, Int64(stageElapsed / 2))
    }

    private static func clamped(_ fraction: Double?) -> Double {
        min(max(fraction ?? 0, 0), 1)
    }
}
