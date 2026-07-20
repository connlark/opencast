import UserNotifications

enum OpenCastNotificationCategory {
    static let episode = "OPENCAST_EPISODE"
    static let adFreePass = "OPENCAST_AD_FREE_PASS"
    static let transcription = "OPENCAST_TRANSCRIPTION"

    /// `setNotificationCategories` replaces the whole set, so every category
    /// must land in the one registration call.
    static func registrationCategories() -> Set<UNNotificationCategory> {
        [
            UNNotificationCategory(
                identifier: episode,
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: adFreePass,
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: transcription,
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
        ]
    }
}
