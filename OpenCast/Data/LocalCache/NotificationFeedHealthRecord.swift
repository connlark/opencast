import Foundation

nonisolated struct NotificationFeedHealthRecord: Equatable, Sendable {
    let feedURL: String
    let health: NotificationFeedHealth
}
