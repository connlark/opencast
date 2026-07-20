import Foundation
import Testing
@testable import OpenCast

@MainActor
struct RemoteTranscriptionBackendConfigurationTests {
    @Test("Release lane resolution is exact and fail closed")
    func releaseLaneResolution() {
        let production = RemoteTranscriptionBackendConfiguration.release(for: .production)
        #expect(production.workerBaseURL == URL(string: "https://remote-transcription.example.com"))
        #expect(
            production.authentication == .appAttest(
                keychainService: RemoteTranscriptionAppAttestKeychainServices.production
            )
        )
        #expect(production.isEnabled)

        for environment in [
            RemoteTranscriptionStoreEnvironment.sandbox,
            .xcode,
        ] {
            let staging = RemoteTranscriptionBackendConfiguration.release(for: environment)
            #expect(staging.workerBaseURL == RemoteTranscriptionBackendConfiguration.prodStagingWorkerBaseURL)
            #expect(
                staging.authentication == .appAttest(
                    keychainService: RemoteTranscriptionAppAttestKeychainServices.prodStaging
                )
            )
            #expect(staging.isEnabled)
        }

        let unknown = RemoteTranscriptionBackendConfiguration.release(for: .unknown("future"))
        #expect(!unknown.isEnabled)
        #expect(!unknown.requiresAppTransaction)
    }

    @Test("Every remote-transcription lane has isolated App Attest credentials")
    func appAttestCredentialsAreIsolated() {
        #expect(RemoteTranscriptionAppAttestKeychainServices.all.count == 3)
        #expect(Set(RemoteTranscriptionAppAttestKeychainServices.all).count == 3)
        #expect(
            RemoteTranscriptionAppAttestKeychainServices.prodStaging
                == "com.connor.opencast.remote-transcription-security.production"
        )
        #expect(
            RemoteTranscriptionAppAttestKeychainServices.production
                != RemoteTranscriptionAppAttestKeychainServices.prodStaging
        )
    }
}
