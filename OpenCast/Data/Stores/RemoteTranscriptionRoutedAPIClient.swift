import Foundation
import OpenCastTranscription

/// Release-only lane router. It resolves AppTransaction once, then pins every
/// request for this process to one concrete API client. An unknown or failed
/// environment lookup never falls back to a money/state lane.
actor RemoteTranscriptionRoutedAPIClient: RemoteTranscriptionAPI {
    private let environmentProvider: @Sendable () async throws -> RemoteTranscriptionStoreEnvironment
    private let clientFactory: @Sendable (
        RemoteTranscriptionBackendConfiguration
    ) -> any RemoteTranscriptionAPI
    private var resolvedClient: (any RemoteTranscriptionAPI)?

    init(
        environmentProvider: @escaping @Sendable () async throws -> RemoteTranscriptionStoreEnvironment =
            RemoteTranscriptionAppTransactionProvider.currentEnvironment,
        clientFactory: @escaping @Sendable (
            RemoteTranscriptionBackendConfiguration
        ) -> any RemoteTranscriptionAPI = { configuration in
            RemoteTranscriptionAPIClient(configuration: configuration)
        }
    ) {
        self.environmentProvider = environmentProvider
        self.clientFactory = clientFactory
    }

    func bootstrap() async throws -> OpenCastRemoteTranscriptionBootstrapResponse {
        try await client().bootstrap()
    }

    func createJob(
        _ request: OpenCastRemoteTranscriptionJobCreateRequest
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        try await client().createJob(request)
    }

    func reportSource(
        jobID: String,
        identity: OpenCastRemoteTranscriptionSourceIdentity
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        try await client().reportSource(jobID: jobID, identity: identity)
    }

    func poll(jobID: String) async throws -> OpenCastRemoteTranscriptionPollResponse {
        try await client().poll(jobID: jobID)
    }

    func uploadStart(
        jobID: String,
        forBackground: Bool
    ) async throws -> OpenCastRemoteTranscriptionUploadGrantResponse {
        try await client().uploadStart(jobID: jobID, forBackground: forBackground)
    }

    func uploadParts(
        jobID: String,
        partNumbers: [Int],
        forBackground: Bool
    ) async throws -> OpenCastRemoteTranscriptionUploadGrantResponse {
        try await client().uploadParts(
            jobID: jobID,
            partNumbers: partNumbers,
            forBackground: forBackground
        )
    }

    func uploadComplete(
        jobID: String,
        parts: [OpenCastRemoteTranscriptionUploadCompletedPart]
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        try await client().uploadComplete(jobID: jobID, parts: parts)
    }

    func result(jobID: String) async throws -> OpenCastRemoteTranscriptionResultResponse {
        try await client().result(jobID: jobID)
    }

    func ack(
        jobID: String,
        normalizedTranscriptSHA256: String?
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        try await client().ack(
            jobID: jobID,
            normalizedTranscriptSHA256: normalizedTranscriptSHA256
        )
    }

    func cancel(jobID: String) async throws -> OpenCastRemoteTranscriptionJobResponse {
        try await client().cancel(jobID: jobID)
    }

    func redeem(
        transactionJWS: String
    ) async throws -> OpenCastRemoteTranscriptionRedeemResponse {
        try await client().redeem(transactionJWS: transactionJWS)
    }

    private func client() async throws -> any RemoteTranscriptionAPI {
        if let resolvedClient {
            return resolvedClient
        }

        let environment = (try? await environmentProvider()) ?? .unknown("unavailable")
        let configuration = RemoteTranscriptionBackendConfiguration.release(for: environment)
        guard configuration.isEnabled else {
            throw RemoteTranscriptionHTTPError(
                statusCode: -1,
                code: OpenCastRemoteTranscriptionErrorCode.featureDisabled.wireValue,
                detail: nil
            )
        }
        let client = clientFactory(configuration)
        resolvedClient = client
        return client
    }
}
