import Foundation
import OpenCastTranscription

/// Typed surface of the remote transcription worker. Injected so simulator
/// tests and UI fixtures run against StoreKit-free fakes.
nonisolated protocol RemoteTranscriptionAPI: Sendable {
    func bootstrap() async throws -> OpenCastRemoteTranscriptionBootstrapResponse
    func createJob(
        _ request: OpenCastRemoteTranscriptionJobCreateRequest
    ) async throws -> OpenCastRemoteTranscriptionJobResponse
    func reportSource(
        jobID: String,
        identity: OpenCastRemoteTranscriptionSourceIdentity
    ) async throws -> OpenCastRemoteTranscriptionJobResponse
    func poll(jobID: String) async throws -> OpenCastRemoteTranscriptionPollResponse
    func uploadStart(
        jobID: String,
        forBackground: Bool
    ) async throws -> OpenCastRemoteTranscriptionUploadGrantResponse
    func uploadParts(
        jobID: String,
        partNumbers: [Int],
        forBackground: Bool
    ) async throws -> OpenCastRemoteTranscriptionUploadGrantResponse
    func uploadComplete(
        jobID: String,
        parts: [OpenCastRemoteTranscriptionUploadCompletedPart]
    ) async throws -> OpenCastRemoteTranscriptionJobResponse
    func result(jobID: String) async throws -> OpenCastRemoteTranscriptionResultResponse
    func ack(
        jobID: String,
        normalizedTranscriptSHA256: String?
    ) async throws -> OpenCastRemoteTranscriptionJobResponse
    func cancel(jobID: String) async throws -> OpenCastRemoteTranscriptionJobResponse
    func redeem(
        transactionJWS: String
    ) async throws -> OpenCastRemoteTranscriptionRedeemResponse
}
