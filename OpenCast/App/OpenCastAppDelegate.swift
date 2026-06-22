import Foundation
import UIKit
import UserNotifications

final class OpenCastAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerNotificationCategories()
        UNUserNotificationCenter.current().delegate = self

        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        RemoteNotificationRegistrationBridge.shared.didRegister(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        RemoteNotificationRegistrationBridge.shared.didFailToRegister(error: error)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        #if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        if Self.notificationKind(from: notification) == "diagnostic" {
            Self.deliverDiagnosticNotification()
        }
        #endif

        completionHandler([.banner, .list, .sound, .badge])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let notification = response.notification
        let isDiagnostic = Self.notificationKind(from: notification) == "diagnostic"
        let route = Self.episodeRoute(from: notification)

        completionHandler()

        #if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        if isDiagnostic {
            Self.deliverDiagnosticNotification()
        } else if let route {
            Self.deliverEpisodeRoute(route)
        }
        #else
        if let route {
            Self.deliverEpisodeRoute(route)
        }
        #endif
    }

    #if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
    nonisolated private static func deliverDiagnosticNotification() {
        Task { @MainActor in
            // Let UIKit's notification completion path unwind before mutating app route state.
            await Task.yield()
            RemoteNotificationRegistrationBridge.shared.didReceiveDiagnosticNotification()
        }
    }
    #endif

    nonisolated private static func deliverEpisodeRoute(_ route: RemoteEpisodeNotificationRoute) {
        Task { @MainActor in
            await Task.yield()
            #if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
            RemoteEpisodeNotificationRouteDiagnostics.shared.record("Delegate Delivered", route: route)
            #endif
            RemoteEpisodeNotificationRouteBridge.shared.didReceive(route: route)
        }
    }

    nonisolated private static func notificationKind(from notification: UNNotification) -> String? {
        let userInfo = notification.request.content.userInfo
        let opencastPayload = userInfo["opencast"] as? [String: Any]
        return opencastPayload?["kind"] as? String
    }

    private func registerNotificationCategories() {
        let episodeCategory = UNNotificationCategory(
            identifier: OpenCastNotificationCategory.episode,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([episodeCategory])
    }

    nonisolated private static func episodeRoute(from notification: UNNotification) -> RemoteEpisodeNotificationRoute? {
        let userInfo = notification.request.content.userInfo
        guard let opencastPayload = userInfo["opencast"] as? [String: Any],
              opencastPayload["kind"] as? String == "episode",
              let feedURL = opencastPayload["feed_url"] as? String,
              let episodeID = opencastPayload["episode_id"] as? String
        else {
            return nil
        }

        return RemoteEpisodeNotificationRoute(
            feedURL: feedURL,
            episodeID: episodeID,
            episodeTitle: opencastPayload["episode_title"] as? String
        )
    }
}
