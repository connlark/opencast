import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

/// Upload-only API fake: serves one scripted geometry and records calls.
private final class FakeUploadOnlyAPI: RemoteTranscriptionAPI, @unchecked Sendable {
    private let lock = NSLock()
    let partCount: Int
    let partSizeBytes: Int64
    let uploadKeyID: String

    private(set) var uploadStartCount = 0
    private(set) var refreshedPartNumbers: [[Int]] = []
    private(set) var completedParts: [[OpenCastRemoteTranscriptionUploadCompletedPart]] = []

    init(partCount: Int, partSizeBytes: Int64, uploadKeyID: String = "upload-key-1") {
        self.partCount = partCount
        self.partSizeBytes = partSizeBytes
        self.uploadKeyID = uploadKeyID
    }

    func uploadStart(
        jobID: String,
        forBackground: Bool
    ) async throws -> OpenCastRemoteTranscriptionUploadGrantResponse {
        lock.withLock { uploadStartCount += 1 }
        return grant(partNumbers: Array(1...partCount))
    }

    func uploadParts(
        jobID: String,
        partNumbers: [Int],
        forBackground: Bool
    ) async throws -> OpenCastRemoteTranscriptionUploadGrantResponse {
        lock.withLock { refreshedPartNumbers.append(partNumbers) }
        return grant(partNumbers: partNumbers)
    }

    func uploadComplete(
        jobID: String,
        parts: [OpenCastRemoteTranscriptionUploadCompletedPart]
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        lock.withLock { completedParts.append(parts) }
        return OpenCastRemoteTranscriptionJobResponse(
            schemaVersion: 1,
            job: OpenCastRemoteTranscriptionJobStatus(jobID: jobID, state: .sourceMatched)
        )
    }

    private func grant(partNumbers: [Int]) -> OpenCastRemoteTranscriptionUploadGrantResponse {
        OpenCastRemoteTranscriptionUploadGrantResponse(
            schemaVersion: 1,
            uploadKeyID: uploadKeyID,
            partSizeBytes: partSizeBytes,
            partCount: partCount,
            parts: partNumbers.map {
                OpenCastRemoteTranscriptionUploadPartGrant(
                    partNumber: $0,
                    url: "https://fake.upload/part/\($0)",
                    expiresAt: Int64(Date.now.timeIntervalSince1970) + 3_600
                )
            }
        )
    }

    // Unused surface for these tests.
    func bootstrap() async throws -> OpenCastRemoteTranscriptionBootstrapResponse {
        throw RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }

    func createJob(
        _ request: OpenCastRemoteTranscriptionJobCreateRequest
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        throw RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }

    func reportSource(
        jobID: String,
        identity: OpenCastRemoteTranscriptionSourceIdentity
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        throw RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }

    func poll(jobID: String) async throws -> OpenCastRemoteTranscriptionPollResponse {
        throw RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }

    func result(jobID: String) async throws -> OpenCastRemoteTranscriptionResultResponse {
        throw RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }

    func ack(
        jobID: String,
        normalizedTranscriptSHA256: String?
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        throw RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }

    func cancel(jobID: String) async throws -> OpenCastRemoteTranscriptionJobResponse {
        throw RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }

    func redeem(
        transactionJWS: String
    ) async throws -> OpenCastRemoteTranscriptionRedeemResponse {
        throw RemoteTranscriptionHTTPError(statusCode: -1, code: "unused", detail: nil)
    }
}

private final class RecordingUploadTransport: RemoteTranscriptionUploadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var failuresRemaining: [Int: Int]
    private(set) var putPartNumbers: [Int] = []
    private(set) var cancelledOutstanding = false
    private(set) var finishedTasks = false

    init(failuresRemaining: [Int: Int] = [:]) {
        self.failuresRemaining = failuresRemaining
    }

    func uploadPart(
        partNumber: Int,
        fileURL: URL,
        to url: URL
    ) async throws -> RemoteTranscriptionUploadPartPutResult {
        let shouldFail = lock.withLock {
            putPartNumbers.append(partNumber)
            let remaining = failuresRemaining[partNumber, default: 0]
            failuresRemaining[partNumber] = max(remaining - 1, 0)
            return remaining > 0
        }
        if shouldFail {
            throw URLError(.networkConnectionLost)
        }
        return RemoteTranscriptionUploadPartPutResult(statusCode: 200, etag: "\"etag-\(partNumber)\"")
    }

    func cancelOutstandingTasks() async {
        lock.withLock { cancelledOutstanding = true }
    }

    func finishTasksAndInvalidate() {
        lock.withLock { finishedTasks = true }
    }
}

@MainActor
@Suite("Remote transcription upload session")
struct RemoteTranscriptionUploadSessionTests {
    private func makeSourceFile(byteCount: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "UploadSessionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: "source.bin")
        try Data((0..<byteCount).map { UInt8($0 % 251) }).write(to: fileURL)
        return fileURL
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "upload-session-tests-\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("Relaunch resume re-PUTs only the missing parts")
    func relaunchResumeRePutsOnlyMissingParts() async throws {
        let jobID = "job-resume-1"
        let defaults = makeDefaults("resume")
        let api = FakeUploadOnlyAPI(partCount: 3, partSizeBytes: 64)
        let sourceFile = try makeSourceFile(byteCount: 64 * 2 + 10)

        // Parts 1 and 2 already uploaded before the "relaunch".
        let persisted = RemoteTranscriptionUploadSession.PersistedState(
            uploadKeyID: "upload-key-1",
            partSizeBytes: 64,
            partCount: 3,
            parts: [
                RemoteTranscriptionUploadSession.PartRecord(partNumber: 1, etag: "etag-1", attempts: 0),
                RemoteTranscriptionUploadSession.PartRecord(partNumber: 2, etag: "etag-2", attempts: 1),
                RemoteTranscriptionUploadSession.PartRecord(partNumber: 3, etag: nil, attempts: 0),
            ]
        )
        defaults.set(
            try JSONEncoder().encode(persisted),
            forKey: RemoteTranscriptionUploadSession.defaultsKey(jobID: jobID)
        )

        let transport = RecordingUploadTransport()
        let session = RemoteTranscriptionUploadSession(
            jobID: jobID,
            sourceFileURL: sourceFile,
            api: api,
            transport: transport,
            defaults: defaults
        )
        try await session.run()

        #expect(transport.putPartNumbers == [3])
        let completed = try #require(api.completedParts.first)
        #expect(completed.map(\.partNumber) == [1, 2, 3])
        #expect(completed.map(\.etag) == ["etag-1", "etag-2", "etag-3"])
        // Completion cleans the persisted state.
        #expect(defaults.data(forKey: RemoteTranscriptionUploadSession.defaultsKey(jobID: jobID)) == nil)
    }

    @Test("A new server upload invalidates stale part bookkeeping")
    func newServerUploadInvalidatesStaleState() async throws {
        let jobID = "job-stale-1"
        let defaults = makeDefaults("stale")
        let api = FakeUploadOnlyAPI(partCount: 2, partSizeBytes: 32, uploadKeyID: "upload-key-NEW")
        let sourceFile = try makeSourceFile(byteCount: 50)

        let stale = RemoteTranscriptionUploadSession.PersistedState(
            uploadKeyID: "upload-key-OLD",
            partSizeBytes: 32,
            partCount: 2,
            parts: [
                RemoteTranscriptionUploadSession.PartRecord(partNumber: 1, etag: "old-etag", attempts: 0),
                RemoteTranscriptionUploadSession.PartRecord(partNumber: 2, etag: nil, attempts: 0),
            ]
        )
        defaults.set(
            try JSONEncoder().encode(stale),
            forKey: RemoteTranscriptionUploadSession.defaultsKey(jobID: jobID)
        )

        let transport = RecordingUploadTransport()
        let session = RemoteTranscriptionUploadSession(
            jobID: jobID,
            sourceFileURL: sourceFile,
            api: api,
            transport: transport,
            defaults: defaults
        )
        try await session.run()

        // Stale ETags never survive into a different upload: both parts PUT.
        #expect(transport.putPartNumbers.sorted() == [1, 2])
        #expect(api.completedParts.first?.map(\.etag) == ["etag-1", "etag-2"])
    }

    @Test("A thrown transport error refreshes the URL and retries the same part")
    func transportErrorRetriesWithFreshGrant() async throws {
        let jobID = "job-transport-retry-1"
        let defaults = makeDefaults("transport-retry")
        let api = FakeUploadOnlyAPI(partCount: 1, partSizeBytes: 32)
        let sourceFile = try makeSourceFile(byteCount: 20)
        let transport = RecordingUploadTransport(failuresRemaining: [1: 1])
        let session = RemoteTranscriptionUploadSession(
            jobID: jobID,
            sourceFileURL: sourceFile,
            api: api,
            transport: transport,
            defaults: defaults
        )

        try await session.run()

        #expect(transport.putPartNumbers == [1, 1])
        #expect(api.refreshedPartNumbers == [[1]])
        #expect(api.completedParts.first?.map(\.etag) == ["etag-1"])
        #expect(transport.finishedTasks)
    }

    @Test("Cancel cleans part files, persisted state, and outstanding tasks")
    func cancelCleansPartFilesAndState() async throws {
        let jobID = "job-cancel-1"
        let defaults = makeDefaults("cancel")
        let api = FakeUploadOnlyAPI(partCount: 2, partSizeBytes: 16)
        let sourceFile = try makeSourceFile(byteCount: 30)

        let transport = RecordingUploadTransport()
        let session = RemoteTranscriptionUploadSession(
            jobID: jobID,
            sourceFileURL: sourceFile,
            api: api,
            transport: transport,
            defaults: defaults
        )
        try await session.run()
        // Re-seed state as if an upload were mid-flight, then cancel.
        defaults.set(Data([1]), forKey: RemoteTranscriptionUploadSession.defaultsKey(jobID: jobID))
        await session.cancelAndCleanUp()

        #expect(transport.cancelledOutstanding)
        #expect(defaults.data(forKey: RemoteTranscriptionUploadSession.defaultsKey(jobID: jobID)) == nil)
        let partDirectory = URL.cachesDirectory
            .appending(path: "RemoteTranscriptionUpload/\(jobID)", directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: partDirectory.path) == false)
    }
}
