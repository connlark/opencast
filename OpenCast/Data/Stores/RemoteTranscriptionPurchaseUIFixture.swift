import Foundation

#if DEBUG
/// StoreKit-free purchase surfaces for deterministic UI verification. The
/// explicit launch argument keeps ordinary DEBUG launches on the real path.
nonisolated enum RemoteTranscriptionPurchaseUIFixture: String {
    case reviewScreenshot = "review-screenshot"
    case unavailable

    static let launchArgument = "-OPENCAST_REMOTE_TRANSCRIPTION_PURCHASE_FIXTURE"

    static func requested(
        _ arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Self? {
        guard let index = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return Self(rawValue: arguments[index + 1])
    }
}
#endif
