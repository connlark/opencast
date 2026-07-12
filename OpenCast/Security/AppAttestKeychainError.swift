import Foundation

struct AppAttestKeychainError: Error, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "Keychain operation failed with status \(status)."
    }
}
