import Foundation

nonisolated struct AppAttestSuspendedError: LocalizedError {
    var errorDescription: String? { "App Attest is suspended while deleting data." }
}
