import Foundation

/// Shared display formatting for credit amounts (integer audio seconds).
nonisolated enum RemoteTranscriptionBalanceFormatting {
    static func hours(_ seconds: Int64) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2)
        )
    }
}
