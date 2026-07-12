#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import Foundation
import Testing
@testable import OpenCast

struct AppAttestCredentialRecoveryTests {
    private struct RecoverableServerError: Error, Equatable {}
    private struct KeychainDeleteError: Error {}

    @Test("Failed key deletion surfaces the original recoverable failure")
    func failedKeyDeletionSurfacesOriginalRecoverableFailure() async {
        var ensureCredentialCalls = 0
        var operationCalls = 0

        await #expect(throws: RecoverableServerError.self) {
            try await AppAttestCredentialRecovery.withFreshCredentialOnRecoverableFailure(
                ensureCredential: {
                    ensureCredentialCalls += 1
                    return "credential"
                },
                deleteCachedAppAttestKey: { throw KeychainDeleteError() },
                isRecoverableServerCredentialFailure: { $0 is RecoverableServerError },
                operation: { (_: String) -> String in
                    operationCalls += 1
                    throw RecoverableServerError()
                }
            )
        }

        #expect(ensureCredentialCalls == 1)
        #expect(operationCalls == 1)
    }

    @Test("Recoverable failure deletes the cached key and retries once")
    func recoverableFailureDeletesCachedKeyAndRetriesOnce() async throws {
        var deletedKeys = 0
        var operationCalls = 0

        let result = try await AppAttestCredentialRecovery.withFreshCredentialOnRecoverableFailure(
            ensureCredential: { "credential" },
            deleteCachedAppAttestKey: { deletedKeys += 1 },
            isRecoverableServerCredentialFailure: { $0 is RecoverableServerError },
            operation: { (_: String) -> String in
                operationCalls += 1
                if operationCalls == 1 {
                    throw RecoverableServerError()
                }
                return "analyzed"
            }
        )

        #expect(result == "analyzed")
        #expect(deletedKeys == 1)
        #expect(operationCalls == 2)
    }
}
#endif
