import DeviceCheck
import Foundation

nonisolated enum AppAttestCredentialRecovery {
    static func withFreshCredentialOnRecoverableFailure<Credential, T>(
        ensureCredential: () async throws -> Credential,
        deleteCachedAppAttestKey: () throws -> Void,
        isRecoverableServerCredentialFailure: (any Error) -> Bool,
        operation: (Credential) async throws -> T
    ) async throws -> T {
        do {
            let credential = try await ensureCredential()
            return try await operation(credential)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error where isRecoverableLocalCredentialFailure(error)
            || isRecoverableServerCredentialFailure(error) {
            do {
                try deleteCachedAppAttestKey()
            } catch _ {
                // Without the deletion the retry would reuse the same stale
                // key; surface the original credential failure rather than
                // masking it with the keychain error.
                throw error
            }
            let credential = try await ensureCredential()
            return try await operation(credential)
        }
    }

    static func isRecoverableLocalCredentialFailure(_ error: any Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == DCError.errorDomain else {
            return false
        }

        return nsError.code == DCError.Code.invalidInput.rawValue
            || nsError.code == DCError.Code.invalidKey.rawValue
    }
}
