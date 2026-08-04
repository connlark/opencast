import Foundation

nonisolated struct FeedMigrationError: Error, LocalizedError, Equatable {
    let message: String

    var errorDescription: String? {
        message
    }
}
