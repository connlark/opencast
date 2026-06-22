import Foundation

nonisolated struct NotificationBackendConfiguration: Sendable {
    let workerBaseURL: URL
    let apnsEnvironment: String
    let keychainService: String

    static let current: Self = {
        #if INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        prodStaging
        #elseif DEBUG
        development
        #else
        production
        #endif
    }()

    private static let development = Self(
        workerBaseURL: URL(string: "https://notifications.example.com/development")!,
        apnsEnvironment: "development",
        keychainService: "com.connor.opencast.notification-security.development"
    )

    private static let prodStaging = Self(
        workerBaseURL: URL(string: "https://notifications.example.com/prod-staging")!,
        apnsEnvironment: "production",
        keychainService: "com.connor.opencast.notification-security.prod-staging"
    )

    private static let production = Self(
        workerBaseURL: URL(string: "https://notifications.example.com")!,
        apnsEnvironment: "production",
        keychainService: "com.connor.opencast.notification-security.production"
    )
}
