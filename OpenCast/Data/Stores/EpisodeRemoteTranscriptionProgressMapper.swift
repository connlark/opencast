import Foundation

/// Maps Transcribe Remotely phases onto the 0–1000 continued-processing
/// band, monotonic-clamped like `EpisodeTranscriptGenerationProgressMapper`.
/// Uploaded parts and the server's chunk fraction move progress inside their
/// bands; the ETA only informs the card's copy. A long phase creeps so the
/// system never reads the card as stalled, capped at the next band's floor.
/// The poll loop can report an earlier phase again, and the clamp holds it.
struct EpisodeRemoteTranscriptionProgressMapper: Equatable {
    static let totalUnitCount: Int64 = 1_000

    private(set) var completedUnitCount: Int64 = 0

    mutating func update(
        for phase: RemoteTranscriptionRequestPhase,
        stageElapsed: TimeInterval = 0
    ) -> Int64 {
        let mappedUnits = Self.units(
            for: phase,
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
        for phase: RemoteTranscriptionRequestPhase,
        stageElapsed: TimeInterval = 0,
        currentUnits: Int64 = 0
    ) -> Int64 {
        let creep = creepUnits(stageElapsed: stageElapsed)
        switch phase {
        case .preparing:
            return min(50, 10 + creep)
        case .downloadingBoth:
            return min(150, 50 + creep)
        case .verifying:
            return min(220, 150 + creep)
        case let .uploadingExactCopy(completedParts, totalParts):
            let uploaded = totalParts > 0 ? Double(completedParts) / Double(totalParts) : 0
            return min(400, 220 + span(170, fraction: uploaded) + creep)
        case .waitingForCredits:
            return min(430, 400 + creep)
        case .processing(let progress):
            switch progress.stage {
            case .checkingAudioDetails:
                return min(470, 430 + creep)
            case .transcribing:
                return min(900, 470 + span(420, fraction: progress.fractionCompleted) + creep)
            case .finalizing:
                return min(950, 900 + creep)
            }
        case .saving:
            return min(990, 950 + creep)
        case .completed:
            return totalUnitCount
        case .parkedOnServer, .mismatchLocalFallback, .failed, .cancelled:
            return currentUnits
        }
    }

    private static func span(_ units: Int64, fraction: Double?) -> Int64 {
        Int64((min(max(fraction ?? 0, 0), 1) * Double(units)).rounded(.down))
    }

    private static func creepUnits(stageElapsed: TimeInterval) -> Int64 {
        max(0, Int64(stageElapsed / 2))
    }
}
