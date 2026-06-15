import Foundation

nonisolated struct LocalLibraryCacheStoreError: LocalizedError, Sendable {
    let operation: String
    let message: String

    var errorDescription: String? {
        "Local library cache \(operation) failed: \(message)"
    }
}
