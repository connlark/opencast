#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import Foundation

nonisolated struct NotificationTestPushResponse: Decodable, Sendable {
    let message: String
    let apnsStatus: Int?
    let apnsID: String?
    let apnsError: String?

    enum CodingKeys: String, CodingKey {
        case message
        case apnsStatus = "apns_status"
        case apnsID = "apns_id"
        case apnsError = "apns_error"
    }
}
#endif
