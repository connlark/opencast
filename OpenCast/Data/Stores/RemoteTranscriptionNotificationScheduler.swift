import Foundation
import OSLog
import UserNotifications

/// Posts the plain Transcribe Remotely notification for a run ending while
/// the scene is not active. Suppression happens at scheduling time:
/// `willPresent` banners everything, so an active-scene ending must never
/// reach `add`. A remote delivery owner takes the completion and the
/// failure; the paused notification posts for either owner.
struct RemoteTranscriptionNotificationScheduler {
    static let threadIdentifier = "opencast-remote-transcription"
    /// A routing no-op for the delegate, which recognizes only "episode"
    /// and "diagnostic".
    static let notificationKind = "remote-transcription"

    private static let logger = Logger(subsystem: "com.connor.opencast", category: "RemoteTranscriptionBackground")

    var center: any AdFreePassNotificationCenter = UNUserNotificationCenter.current()

    @discardableResult
    func scheduleIfNeeded(
        phase: RemoteTranscriptionRequestPhase,
        episodeTitle: String?,
        deliveryOwner: JobCompletionDeliveryOwner,
        isSceneActive: Bool,
        createState: RemoteTranscriptionJobCreateState? = nil
    ) async -> CompletionDeliveryDecision {
        guard let content = RemoteTranscriptionNotificationContent(
            phase: phase,
            episodeTitle: episodeTitle,
            createState: createState
        ) else {
            return .suppressed(.silentOutcome)
        }
        if content.honorsDeliveryOwner, deliveryOwner == .remote {
            return .suppressed(.remoteOwner)
        }
        guard !isSceneActive else {
            return .suppressed(.sceneActive)
        }
        guard AdFreePassCompletionNotificationScheduler.allowsLocalDelivery(await center.authorizationStatus()) else {
            return .suppressed(.unauthorized)
        }

        let request = UNNotificationRequest(
            identifier: "\(Self.threadIdentifier)-\(UUID().uuidString)",
            content: Self.notificationContent(for: content),
            trigger: nil
        )
        do {
            try await center.add(request)
            AdFreePassBackgroundRunLog.record("remote transcription notification scheduled title=\(content.title)")
            return .scheduled
        } catch {
            // The run log is DEBUG-only; the logger line is the Release artifact.
            AdFreePassBackgroundRunLog.record("remote transcription notification add failed error=\(error)")
            Self.logger.error("remote transcription notification add failed: \(error.localizedDescription, privacy: .public)")
            return .addFailed
        }
    }

    static func notificationContent(
        for content: RemoteTranscriptionNotificationContent
    ) -> UNMutableNotificationContent {
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        notification.sound = .default
        notification.categoryIdentifier = OpenCastNotificationCategory.transcription
        notification.threadIdentifier = threadIdentifier
        notification.userInfo = ["opencast": ["kind": notificationKind]]
        return notification
    }
}
