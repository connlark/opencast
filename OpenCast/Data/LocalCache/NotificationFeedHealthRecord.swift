import Foundation

/// One feed's server-reported notification poll health, persisted
/// device-local and replaced wholesale from each successful sync response.
nonisolated struct NotificationFeedHealthRecord: Equatable, Sendable {
    let feedURL: String
    let health: NotificationFeedHealth
}
