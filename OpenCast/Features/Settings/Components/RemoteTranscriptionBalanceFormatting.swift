import Foundation

nonisolated enum RemoteTranscriptionBalanceFormatting {
    static func hours(_ seconds: Int64) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2)
        )
    }
}
