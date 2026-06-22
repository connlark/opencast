import Foundation

struct NotificationSecurityKeychainError: Error, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "Keychain operation failed with status \(status)."
    }
}
