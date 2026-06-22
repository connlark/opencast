#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import Foundation

nonisolated struct NotificationTestPushPayload: Encodable, Sendable {
    let title: String?
    let body: String?

    init(title: String? = nil, body: String? = nil) {
        self.title = title
        self.body = body
    }
}
#endif
