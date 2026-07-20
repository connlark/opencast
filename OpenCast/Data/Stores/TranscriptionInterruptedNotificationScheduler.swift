import Foundation
import UserNotifications

struct TranscriptionInterruptedNotificationScheduler {
    static let threadIdentifier = "opencast-transcription-interrupted"

    var center: any AdFreePassNotificationCenter = UNUserNotificationCenter.current()

    func scheduleIfNeeded(
        content: TranscriptionInterruptedNotificationContent,
        isSceneActive: Bool
    ) async {
        guard !isSceneActive,
              AdFreePassCompletionNotificationScheduler.allowsLocalDelivery(
                  await center.authorizationStatus()
              )
        else {
            return
        }

        let request = UNNotificationRequest(
            identifier: "\(Self.threadIdentifier)-\(UUID().uuidString)",
            content: Self.notificationContent(for: content),
            trigger: nil
        )
        do {
            try await center.add(request)
            AdFreePassBackgroundRunLog.record("transcription interruption notification scheduled title=\(content.title)")
        } catch {
            AdFreePassBackgroundRunLog.record("transcription interruption notification add failed error=\(error)")
        }
    }

    static func notificationContent(
        for content: TranscriptionInterruptedNotificationContent
    ) -> UNMutableNotificationContent {
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        notification.sound = .default
        notification.categoryIdentifier = OpenCastNotificationCategory.transcription
        notification.threadIdentifier = threadIdentifier
        notification.userInfo = ["opencast": ["kind": "transcription-interrupted"]]
        return notification
    }
}
