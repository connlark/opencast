import Foundation
import OSLog
import UserNotifications

/// Posts the local "ad detection finished" notification when a queue drain
/// ends while the scene is not active. Suppression happens at scheduling
/// time — `willPresent` banners everything, so an active-scene drain must
/// never reach `add`.
struct AdFreePassCompletionNotificationScheduler {
    static let threadIdentifier = "opencast-ad-free-pass-completion"

    private static let logger = Logger(subsystem: "com.connor.opencast", category: "AdFreePassBackground")

    var center: any AdFreePassNotificationCenter = UNUserNotificationCenter.current()

    @discardableResult
    func scheduleIfNeeded(
        terminal: AdFreePassQueueTerminalOutcome,
        outcomes: [AdFreePassQueueItemOutcome],
        isSceneActive: Bool
    ) async -> CompletionDeliveryDecision {
        guard !isSceneActive else {
            return .suppressed(.sceneActive)
        }
        guard let content = AdFreePassCompletionNotificationContent(terminal: terminal, outcomes: outcomes) else {
            return .suppressed(.silentOutcome)
        }
        guard Self.allowsLocalDelivery(await center.authorizationStatus()) else {
            return .suppressed(.unauthorized)
        }

        let request = UNNotificationRequest(
            identifier: "\(Self.threadIdentifier)-\(UUID().uuidString)",
            content: Self.notificationContent(for: content),
            trigger: nil
        )
        do {
            try await center.add(request)
            AdFreePassBackgroundRunLog.record("completion notification scheduled title=\(content.title)")
            return .scheduled
        } catch {
            // The run log is DEBUG-only; the logger line is the Release artifact.
            AdFreePassBackgroundRunLog.record("completion notification add failed error=\(error)")
            Self.logger.error("ad-free pass completion notification add failed: \(error.localizedDescription, privacy: .public)")
            return .addFailed
        }
    }

    static func notificationContent(
        for content: AdFreePassCompletionNotificationContent
    ) -> UNMutableNotificationContent {
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        notification.sound = .default
        notification.categoryIdentifier = OpenCastNotificationCategory.adFreePass
        notification.threadIdentifier = threadIdentifier
        // The delegate's kind router only recognizes "episode" and
        // "diagnostic"; this kind is a deliberate routing no-op.
        notification.userInfo = ["opencast": ["kind": "ad-free-pass"]]
        return notification
    }

    static func allowsLocalDelivery(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            true
        case .denied, .notDetermined:
            false
        @unknown default:
            false
        }
    }
}
