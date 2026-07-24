import CryptoKit
import Foundation
import OpenCastTranscription
import SwiftData
import Testing
@testable import OpenCast

/// C6: StoreKit-free fake for the remote transcription API. Poll states are
/// consumed in order and the last one repeats, so tests script exact state
/// journeys; every mutation is recorded for ordering assertions.
private final class FakeRemoteTranscriptionAPI: RemoteTranscriptionAPI, @unchecked Sendable {
    let jobID = "job-fake-1"

    /// Server-decided upload geometry for tests that exercise the
    /// exact-device fallback; nil rejects upload routes like a job that
    /// never required one.
    struct UploadScript {
        var partCount: Int
        var partSizeBytes: Int64
    }

    private let lock = NSLock()
    private var pollStates: [OpenCastRemoteTranscriptionJobStatus]
    private var transientPollErrors: [Error]
    private let pollError: Error?
    private let resultResponse: OpenCastRemoteTranscriptionResultResponse?
    private let ackError: Error?
    private let onAck: (@Sendable () async -> Void)?
    private let uploadScript: UploadScript?

    private(set) var createRequests: [OpenCastRemoteTranscriptionJobCreateRequest] = []
    private(set) var reportedIdentities: [OpenCastRemoteTranscriptionSourceIdentity] = []
    private(set) var resultCallCount = 0
    private(set) var ackHashes: [String?] = []
    private(set) var cancelledJobIDs: [String] = []
    private(set) var uploadStartCount = 0
    private(set) var refreshedPartNumbers: [[Int]] = []
    private(set) var completedUploadParts: [[OpenCastRemoteTranscriptionUploadCompletedPart]] = []

    init(
        pollStates: [OpenCastRemoteTranscriptionJobStatus],
        transientPollErrors: [Error] = [],
        pollError: Error? = nil,
        resultResponse: OpenCastRemoteTranscriptionResultResponse? = nil,
        ackError: Error? = nil,
        onAck: (@Sendable () async -> Void)? = nil,
        uploadScript: UploadScript? = nil
    ) {
        self.pollStates = pollStates
        self.transientPollErrors = transientPollErrors
        self.pollError = pollError
        self.resultResponse = resultResponse
        self.ackError = ackError
        self.onAck = onAck
        self.uploadScript = uploadScript
    }

    func bootstrap() async throws -> OpenCastRemoteTranscriptionBootstrapResponse {
        OpenCastRemoteTranscriptionBootstrapResponse(
            schemaVersion: 1,
            accountID: "acct-fake",
            balance: OpenCastRemoteTranscriptionBalance(availableSeconds: 36_000, reservedSeconds: 0)
        )
    }

    func createJob(
        _ request: OpenCastRemoteTranscriptionJobCreateRequest
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        lock.withLock { createRequests.append(request) }
        return OpenCastRemoteTranscriptionJobResponse(
            schemaVersion: 1,
            job: OpenCastRemoteTranscriptionJobStatus(jobID: jobID, state: .created)
        )
    }

    func reportSource(
        jobID: String,
        identity: OpenCastRemoteTranscriptionSourceIdentity
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        lock.withLock { reportedIdentities.append(identity) }
        return OpenCastRemoteTranscriptionJobResponse(
            schemaVersion: 1,
            job: OpenCastRemoteTranscriptionJobStatus(jobID: jobID, state: .sourceMatched)
        )
    }

    func poll(jobID: String) async throws -> OpenCastRemoteTranscriptionPollResponse {
        // Transient errors are consumed one per call before any state is
        // served, so tests can script a blip the retry grace must absorb.
        let transient: Error? = lock.withLock {
            transientPollErrors.isEmpty ? nil : transientPollErrors.removeFirst()
        }
        if let transient {
            throw transient
        }
        // Without a pollError the last scripted state repeats forever; with
        // one, the states are consumed and then the backend goes unreachable.
        let job: OpenCastRemoteTranscriptionJobStatus? = lock.withLock {
            if pollStates.isEmpty {
                return nil
            }
            if pollStates.count > 1 || pollError != nil {
                return pollStates.removeFirst()
            }
            return pollStates[0]
        }
        guard let job else {
            throw pollError ?? RemoteTranscriptionHTTPError(statusCode: -1, code: "poll_exhausted", detail: nil)
        }
        return OpenCastRemoteTranscriptionPollResponse(schemaVersion: 1, job: job, pollAfterSeconds: 0)
    }

    func result(jobID: String) async throws -> OpenCastRemoteTranscriptionResultResponse {
        lock.withLock { resultCallCount += 1 }
        guard let resultResponse else {
            throw RemoteTranscriptionHTTPError(statusCode: 404, code: "not_found", detail: nil)
        }
        return resultResponse
    }

    func ack(
        jobID: String,
        normalizedTranscriptSHA256: String?
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        await onAck?()
        if let ackError {
            throw ackError
        }
        lock.withLock { ackHashes.append(normalizedTranscriptSHA256) }
        return OpenCastRemoteTranscriptionJobResponse(
            schemaVersion: 1,
            job: OpenCastRemoteTranscriptionJobStatus(jobID: jobID, state: .acknowledged)
        )
    }

    func cancel(jobID: String) async throws -> OpenCastRemoteTranscriptionJobResponse {
        lock.withLock { cancelledJobIDs.append(jobID) }
        return OpenCastRemoteTranscriptionJobResponse(
            schemaVersion: 1,
            job: OpenCastRemoteTranscriptionJobStatus(jobID: jobID, state: .cancelled)
        )
    }

    func uploadStart(
        jobID: String,
        forBackground: Bool
    ) async throws -> OpenCastRemoteTranscriptionUploadGrantResponse {
        guard let uploadScript else {
            throw RemoteTranscriptionHTTPError(statusCode: 409, code: "invalid_request", detail: nil)
        }
        lock.withLock { uploadStartCount += 1 }
        return grantResponse(script: uploadScript, partNumbers: Array(1...uploadScript.partCount))
    }

    func uploadParts(
        jobID: String,
        partNumbers: [Int],
        forBackground: Bool
    ) async throws -> OpenCastRemoteTranscriptionUploadGrantResponse {
        guard let uploadScript else {
            throw RemoteTranscriptionHTTPError(statusCode: 409, code: "invalid_request", detail: nil)
        }
        lock.withLock { refreshedPartNumbers.append(partNumbers) }
        return grantResponse(script: uploadScript, partNumbers: partNumbers, refreshed: true)
    }

    func uploadComplete(
        jobID: String,
        parts: [OpenCastRemoteTranscriptionUploadCompletedPart]
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        lock.withLock { completedUploadParts.append(parts) }
        return OpenCastRemoteTranscriptionJobResponse(
            schemaVersion: 1,
            job: OpenCastRemoteTranscriptionJobStatus(jobID: jobID, state: .sourceMatched)
        )
    }

    private func grantResponse(
        script: UploadScript,
        partNumbers: [Int],
        refreshed: Bool = false
    ) -> OpenCastRemoteTranscriptionUploadGrantResponse {
        let prefix = refreshed ? "refreshed" : "part"
        return OpenCastRemoteTranscriptionUploadGrantResponse(
            schemaVersion: 1,
            uploadKeyID: "upload-key-1",
            partSizeBytes: script.partSizeBytes,
            partCount: script.partCount,
            parts: partNumbers.map { number in
                OpenCastRemoteTranscriptionUploadPartGrant(
                    partNumber: number,
                    url: "https://fake.upload/\(prefix)/\(number)",
                    expiresAt: Int64(Date.now.timeIntervalSince1970) + 3_600
                )
            }
        )
    }

    func redeem(
        transactionJWS: String
    ) async throws -> OpenCastRemoteTranscriptionRedeemResponse {
        throw RemoteTranscriptionHTTPError(statusCode: 503, code: "feature_disabled", detail: nil)
    }
}

/// Deterministic upload transport: records every PUT and serves scripted
/// results (default: 200 with a per-part ETag).
private final class FakeUploadTransport: RemoteTranscriptionUploadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var scriptedResults: [Int: [RemoteTranscriptionUploadPartPutResult]]

    private(set) var putPartNumbers: [Int] = []
    private(set) var putURLStrings: [Int: [String]] = [:]
    private(set) var putFileSizes: [Int: [Int]] = [:]
    private(set) var cancelledOutstanding = false

    init(scriptedResults: [Int: [RemoteTranscriptionUploadPartPutResult]] = [:]) {
        self.scriptedResults = scriptedResults
    }

    func uploadPart(
        partNumber: Int,
        fileURL: URL,
        to url: URL
    ) async throws -> RemoteTranscriptionUploadPartPutResult {
        let size = (try? Data(contentsOf: fileURL).count) ?? -1
        return lock.withLock {
            putPartNumbers.append(partNumber)
            putURLStrings[partNumber, default: []].append(url.absoluteString)
            putFileSizes[partNumber, default: []].append(size)
            if var queue = scriptedResults[partNumber], queue.isEmpty == false {
                let next = queue.removeFirst()
                scriptedResults[partNumber] = queue
                return next
            }
            return RemoteTranscriptionUploadPartPutResult(statusCode: 200, etag: "\"etag-\(partNumber)\"")
        }
    }

    func cancelOutstandingTasks() async {
        lock.withLock { cancelledOutstanding = true }
    }

    func finishTasksAndInvalidate() {}
}

/// Minimal thread-safe flag/box helpers for cross-context assertions.
private final class OpenCastAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.withLock { value }
    }

    func set() {
        lock.withLock { value = true }
    }
}

private final class OpenCastUncheckedSendableBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: - Shared fixture builders

private enum RemoteFixtures {
    static let provider = "cloudflare-workers-ai"
    static let model = "@cf/openai/whisper-large-v3-turbo"

    static func identity(for data: Data, duration: Double?) -> OpenCastRemoteTranscriptionSourceIdentity {
        OpenCastRemoteTranscriptionSourceIdentity(
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: Int64(data.count),
            durationSeconds: duration
        )
    }

    /// A result whose segments/words and normalized hash are self-consistent,
    /// so it passes mapper validation against the given identity.
    static func result(
        identity: OpenCastRemoteTranscriptionSourceIdentity,
        durationSeconds: Double,
        pipelineVersion: String = "stitch-v3"
    ) -> OpenCastRemoteTranscriptionResult {
        let words = [
            OpenCastRemoteTranscriptWord(start: 0.0, end: 0.6, text: "Hello"),
            OpenCastRemoteTranscriptWord(start: 0.6, end: 1.1, text: "remote"),
            OpenCastRemoteTranscriptWord(start: 1.1, end: 1.7, text: "transcript."),
        ]
        let normalized = OpenCastRemoteTranscriptNormalization.normalizedTranscriptSHA256(
            words.map(\.text).joined(separator: " ")
        )
        return OpenCastRemoteTranscriptionResult(
            schemaVersion: 1,
            sourceIdentity: identity,
            languageCode: "en",
            durationSeconds: durationSeconds,
            text: "Hello remote transcript.",
            segments: [
                OpenCastRemoteTranscriptSegment(
                    id: 0,
                    start: 0.0,
                    end: 1.7,
                    text: "Hello remote transcript.",
                    words: words
                ),
            ],
            provenance: OpenCastRemoteTranscriptionModelProvenance(
                provider: provider,
                modelIdentifier: model,
                modelRevision: nil,
                servingContractVersion: "1",
                requestSettingsSHA256: String(repeating: "a", count: 64),
                chunkManifestSHA256: String(repeating: "b", count: 64),
                normalizedTranscriptSHA256: normalized,
                pipelineVersion: pipelineVersion
            ),
            warnings: []
        )
    }
}

// MARK: - Mapper

@MainActor
@Suite("Remote transcript mapper")
struct EpisodeRemoteTranscriptMapperTests {
    private let data = Data("remote audio bytes".utf8)

    private var identity: OpenCastRemoteTranscriptionSourceIdentity {
        RemoteFixtures.identity(for: data, duration: 120)
    }

    private func context(
        identity: OpenCastRemoteTranscriptionSourceIdentity
    ) -> EpisodeRemoteTranscriptMapper.Context {
        EpisodeRemoteTranscriptMapper.Context(
            episodeID: "ep-map",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/ep-map.mp3",
            localIdentity: identity,
            jobProvenanceToken: "job-fake-1"
        )
    }

    @Test("Valid result maps to a schema-3 remote document")
    func validResultMapsToSchema3Document() throws {
        let result = RemoteFixtures.result(identity: identity, durationSeconds: 120.4)

        let document = try EpisodeRemoteTranscriptMapper.document(
            from: result,
            context: context(identity: identity)
        )

        #expect(document.schemaVersion == EpisodeTranscriptDocument.currentSchemaVersion)
        #expect(document.resolvedEngineProvenance == .remoteWhisper)
        #expect(document.providerModelIdentifier == RemoteFixtures.model)
        #expect(document.modelIdentifier == RemoteFixtures.model)
        #expect(document.modelTreeSHA256.isEmpty)
        #expect(document.remotePipelineVersion == "stitch-v3")
        #expect(document.remoteJobProvenanceToken == "job-fake-1")
        #expect(document.remoteSourceMatchMode == EpisodeRemoteTranscriptSourceMatchMode.serverDeviceHashMatch.rawValue)
        #expect(document.normalizedTranscriptSHA256 == result.provenance.normalizedTranscriptSHA256)
        #expect(document.sourceFileSHA256 == identity.sha256)
        #expect(document.segments.count == 1)
        #expect(document.segments[0].words?.count == 3)
    }

    @Test("Minted document dates carry no fractional seconds")
    func mintedDatesAreWholeSeconds() throws {
        let result = RemoteFixtures.result(identity: identity, durationSeconds: 120.4)

        let document = try EpisodeRemoteTranscriptMapper.document(
            from: result,
            context: context(identity: identity)
        )

        // The in-memory document must equal its `.iso8601` disk round trip
        // (which drops fractional seconds): the ad-analysis freshness checks
        // compare a record seeded from this document against the reloaded one.
        #expect(document.createdAt.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) == 0)
        #expect(document.updatedAt.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) == 0)
    }

    @Test("Normalizes a remote tail word that overlaps the next segment")
    func normalizesTailWordOverlappingNextSegment() throws {
        var result = RemoteFixtures.result(identity: identity, durationSeconds: 120.4)
        result.text = "First tail. Second line."
        result.segments = [
            OpenCastRemoteTranscriptSegment(
                id: 8,
                start: 0,
                end: 2,
                text: "First tail.",
                words: [
                    OpenCastRemoteTranscriptWord(start: 0, end: 1, text: "First"),
                    OpenCastRemoteTranscriptWord(start: 1.9, end: 2, text: "tail.")
                ]
            ),
            OpenCastRemoteTranscriptSegment(
                id: 4,
                start: 1.8,
                end: 3,
                text: "Second line.",
                words: [
                    OpenCastRemoteTranscriptWord(start: 2, end: 2.5, text: "Second"),
                    OpenCastRemoteTranscriptWord(start: 2.5, end: 3, text: "line.")
                ]
            )
        ]
        result.provenance.normalizedTranscriptSHA256 =
            OpenCastRemoteTranscriptNormalization.normalizedTranscriptSHA256(result.text)

        let document = try EpisodeRemoteTranscriptMapper.document(
            from: result,
            context: context(identity: identity)
        )

        #expect(document.segments.map(\.id) == [0, 1])
        #expect(document.segments.map(\.start) == [0, 2])
        #expect(document.segments.map(\.end) == [2, 3])
        #expect(document.segments[0].words?.last?.start == 1.9)
        #expect(document.segments[1].words?.first?.start == 2)
    }

    @Test("Rejects a source hash mismatch")
    func rejectsSourceHashMismatch() {
        let remoteIdentity = OpenCastRemoteTranscriptionSourceIdentity(
            sha256: String(repeating: "f", count: 64),
            byteCount: identity.byteCount
        )
        let result = RemoteFixtures.result(identity: remoteIdentity, durationSeconds: 120.4)

        #expect(throws: EpisodeRemoteTranscriptMapper.ValidationError.sourceIdentityMismatch) {
            try EpisodeRemoteTranscriptMapper.document(from: result, context: context(identity: identity))
        }
    }

    @Test("Rejects a byte count mismatch")
    func rejectsByteCountMismatch() {
        var remoteIdentity = identity
        remoteIdentity.byteCount += 1
        let result = RemoteFixtures.result(identity: remoteIdentity, durationSeconds: 120.4)

        #expect(throws: EpisodeRemoteTranscriptMapper.ValidationError.sourceIdentityMismatch) {
            try EpisodeRemoteTranscriptMapper.document(from: result, context: context(identity: identity))
        }
    }

    @Test("Exact SHA-256 and byte count do not depend on duration metadata")
    func exactIdentityDoesNotDependOnDurationMetadata() throws {
        let result = RemoteFixtures.result(identity: identity, durationSeconds: 150)

        let document = try EpisodeRemoteTranscriptMapper.document(
            from: result,
            context: context(identity: identity)
        )

        #expect(document.audioDuration == 150)
    }

    @Test("Rejects a non-finite canonical duration")
    func rejectsNonFiniteDuration() {
        let result = RemoteFixtures.result(identity: identity, durationSeconds: .nan)

        #expect(throws: EpisodeRemoteTranscriptMapper.ValidationError.invalidDuration) {
            try EpisodeRemoteTranscriptMapper.document(from: result, context: context(identity: identity))
        }
    }

    @Test("Rejects non-monotonic word timings")
    func rejectsNonMonotonicWordTimings() {
        var result = RemoteFixtures.result(identity: identity, durationSeconds: 120.4)
        result.segments[0].words?[2].start = 0.1

        #expect(throws: EpisodeRemoteTranscriptMapper.ValidationError.invalidTimings) {
            try EpisodeRemoteTranscriptMapper.document(from: result, context: context(identity: identity))
        }
    }

    @Test("Rejects a word whose end precedes its start")
    func rejectsReversedWordTiming() {
        var result = RemoteFixtures.result(identity: identity, durationSeconds: 120.4)
        result.segments[0].words?[1].end = 0.5

        #expect(throws: EpisodeRemoteTranscriptMapper.ValidationError.invalidTimings) {
            try EpisodeRemoteTranscriptMapper.document(from: result, context: context(identity: identity))
        }
    }

    @Test("Rejects segments whose starts move backwards")
    func rejectsNonmonotonicSegments() {
        var result = RemoteFixtures.result(identity: identity, durationSeconds: 120.4)
        result.segments[0].start = 0.5
        var second = result.segments[0]
        second.id = 1
        second.start = 0.4
        result.segments.append(second)

        #expect(throws: EpisodeRemoteTranscriptMapper.ValidationError.invalidTimings) {
            try EpisodeRemoteTranscriptMapper.document(from: result, context: context(identity: identity))
        }
    }

    @Test("Rejects transcript text that disagrees with verified words")
    func rejectsTextMismatch() {
        var result = RemoteFixtures.result(identity: identity, durationSeconds: 120.4)
        result.text = "different text"

        #expect(throws: EpisodeRemoteTranscriptMapper.ValidationError.textMismatch) {
            try EpisodeRemoteTranscriptMapper.document(from: result, context: context(identity: identity))
        }
    }

    @Test("Rejects segment text that disagrees with verified words")
    func rejectsSegmentTextMismatch() {
        var result = RemoteFixtures.result(identity: identity, durationSeconds: 120.4)
        result.segments[0].text = "different segment text"

        #expect(throws: EpisodeRemoteTranscriptMapper.ValidationError.textMismatch) {
            try EpisodeRemoteTranscriptMapper.document(from: result, context: context(identity: identity))
        }
    }

    @Test("Rejects nonempty segment text without words")
    func rejectsNonemptySegmentWithoutWords() {
        var result = RemoteFixtures.result(identity: identity, durationSeconds: 120.4)
        result.segments[0].words = nil

        #expect(throws: EpisodeRemoteTranscriptMapper.ValidationError.textMismatch) {
            try EpisodeRemoteTranscriptMapper.document(from: result, context: context(identity: identity))
        }
    }

    @Test("Rejects an empty word")
    func rejectsEmptyWord() {
        var result = RemoteFixtures.result(identity: identity, durationSeconds: 120.4)
        result.segments[0].words?[0].text = " "

        #expect(throws: EpisodeRemoteTranscriptMapper.ValidationError.emptyTranscript) {
            try EpisodeRemoteTranscriptMapper.document(from: result, context: context(identity: identity))
        }
    }

    @Test("Rejects a normalized hash mismatch")
    func rejectsNormalizedHashMismatch() {
        var result = RemoteFixtures.result(identity: identity, durationSeconds: 120.4)
        result.provenance.normalizedTranscriptSHA256 = String(repeating: "0", count: 64)

        #expect(throws: EpisodeRemoteTranscriptMapper.ValidationError.normalizedHashMismatch) {
            try EpisodeRemoteTranscriptMapper.document(from: result, context: context(identity: identity))
        }
    }

    @Test("Rejects an empty transcript")
    func rejectsEmptyTranscript() {
        var result = RemoteFixtures.result(identity: identity, durationSeconds: 120.4)
        result.segments = []

        #expect(throws: EpisodeRemoteTranscriptMapper.ValidationError.emptyTranscript) {
            try EpisodeRemoteTranscriptMapper.document(from: result, context: context(identity: identity))
        }
    }
}

// MARK: - Coordinator

@MainActor
@Suite("Remote transcription coordinator", .serialized)
struct EpisodeRemoteTranscriptionCoordinatorTests {
    private struct Environment {
        var coordinator: EpisodeRemoteTranscriptionCoordinator
        var runner: RemoteTranscriptionJobRunner
        var api: FakeRemoteTranscriptionAPI
        var store: RemoteTranscriptionJobStore
        var transcriptions: EpisodeTranscriptionStore
        var context: ModelContext
        var episode: EpisodeListItemSnapshot
        var identity: OpenCastRemoteTranscriptionSourceIdentity
    }

    /// A full environment around one completed, hashed download so the
    /// coordinator can proceed without any downloader. Retry delays default
    /// to none so unreachable-backend scripts fail fast in tests.
    private func makeEnvironment(
        api: FakeRemoteTranscriptionAPI,
        episodeID: String,
        uploadTransport: FakeUploadTransport? = nil,
        transportRetryDelays: [Duration] = []
    ) throws -> Environment {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let downloadFileStore = EpisodeDownloadFileStore(baseDirectory: try makeTemporaryDirectory())
        let downloads = DownloadStore(fileStore: downloadFileStore)
        let transcriptions = EpisodeTranscriptionStore(
            fileStore: EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        let episode = makeEpisode(episodeID: episodeID)

        let sourceURL = URL(string: episode.audioURL!)!
        let relativePath = downloadFileStore.relativePath(episodeID: episodeID, sourceAudioURL: sourceURL)
        let fileURL = downloadFileStore.fileURL(relativePath: relativePath)
        let data = Data("remote audio bytes \(episodeID)".utf8)
        try downloadFileStore.prepareDownloadsDirectory()
        try data.write(to: fileURL, options: .atomic)
        let identity = RemoteFixtures.identity(for: data, duration: 120)
        let record = EpisodeDownloadRecord(
            episodeID: episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: sourceURL.absoluteString,
            localRelativePath: relativePath,
            state: .completed,
            bytesReceived: Int64(data.count),
            bytesExpected: Int64(data.count)
        )
        record.sourceFileSHA256 = identity.sha256
        record.duration = 120
        context.insert(record)
        try context.save()
        downloads.load(modelContext: context)

        let suiteName = "remote-coordinator-tests-\(episodeID)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = RemoteTranscriptionJobStore(defaults: defaults)
        let coordinator = EpisodeRemoteTranscriptionCoordinator(
            api: api,
            downloads: downloads,
            transcriptions: transcriptions,
            store: store,
            uploadSessionFactory: uploadTransport.map { transport in
                { jobID, sourceFileURL in
                    RemoteTranscriptionUploadSession(
                        jobID: jobID,
                        sourceFileURL: sourceFileURL,
                        api: api,
                        transport: transport,
                        defaults: defaults
                    )
                }
            },
            transportRetryDelays: transportRetryDelays
        )
        let runner = RemoteTranscriptionJobRunner(
            api: api,
            downloads: downloads,
            transcriptions: transcriptions,
            store: store,
            transportRetryDelays: transportRetryDelays
        )
        return Environment(
            coordinator: coordinator,
            runner: runner,
            api: api,
            store: store,
            transcriptions: transcriptions,
            context: context,
            episode: episode,
            identity: identity
        )
    }

    @Test("Happy path ignores unmeasured RSS duration, imports before ack, and completes")
    func happyPathIgnoresUnmeasuredRSSDurationAndCompletes() async throws {
        let identityData = Data("remote audio bytes ep-happy".utf8)
        let identity = RemoteFixtures.identity(for: identityData, duration: 120)
        let result = RemoteFixtures.result(identity: identity, durationSeconds: 150)
        let api = FakeRemoteTranscriptionAPI(
            pollStates: [
                OpenCastRemoteTranscriptionJobStatus(
                    jobID: "job-fake-1",
                    state: .transcribing,
                    progress: OpenCastRemoteTranscriptionJobProgress(chunksCompleted: 1, chunksTotal: 1)
                ),
                OpenCastRemoteTranscriptionJobStatus(jobID: "job-fake-1", state: .resultReady),
            ],
            resultResponse: OpenCastRemoteTranscriptionResultResponse(schemaVersion: 1, result: result)
        )
        let environment = try makeEnvironment(api: api, episodeID: "ep-happy")

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)

        #expect(await waitUntil { environment.store.phase == .completed })
        #expect(api.createRequests.count == 1)
        #expect(api.createRequests[0].sourceIdentity?.sha256 == identity.sha256)
        #expect(api.createRequests[0].sourceIdentity?.durationSeconds == nil)
        #expect(api.reportedIdentities.map(\.sha256) == [identity.sha256])
        #expect(api.reportedIdentities.map(\.durationSeconds) == [nil])
        #expect(api.resultCallCount == 1)
        #expect(api.ackHashes == [result.provenance.normalizedTranscriptSHA256])
        let record = try #require(environment.transcriptions.record(for: "ep-happy"))
        #expect(record.engineProvenance == .remoteWhisper)
        let document = try #require(environment.transcriptions.document(for: "ep-happy"))
        #expect(document.text == "Hello remote transcript.")
        #expect(environment.store.references().isEmpty)
    }

    @Test("Ack failure never fails the request: the import is already durable")
    func ackFailureNeverFailsTheRequest() async throws {
        let identityData = Data("remote audio bytes ep-ack-fail".utf8)
        let identity = RemoteFixtures.identity(for: identityData, duration: 120)
        let result = RemoteFixtures.result(identity: identity, durationSeconds: 120.4)
        let transcriptWasImportedAtAck = OpenCastAtomicFlag()
        let transcriptions = OpenCastUncheckedSendableBox<EpisodeTranscriptionStore?>(nil)
        let api = FakeRemoteTranscriptionAPI(
            pollStates: [OpenCastRemoteTranscriptionJobStatus(jobID: "job-fake-1", state: .resultReady)],
            resultResponse: OpenCastRemoteTranscriptionResultResponse(schemaVersion: 1, result: result),
            ackError: RemoteTranscriptionHTTPError(statusCode: 503, code: "unavailable", detail: nil),
            onAck: {
                // Ordering proof: the durable record must exist before the
                // coordinator ever attempts the ack.
                let imported = await MainActor.run {
                    transcriptions.value?.record(for: "ep-ack-fail")?.state == .completed
                }
                if imported {
                    transcriptWasImportedAtAck.set()
                }
            }
        )
        let environment = try makeEnvironment(api: api, episodeID: "ep-ack-fail")
        transcriptions.value = environment.transcriptions

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)

        #expect(await waitUntil { environment.store.phase == .completed })
        #expect(transcriptWasImportedAtAck.isSet)
        #expect(environment.transcriptions.document(for: "ep-ack-fail") != nil)
    }

    @Test("Source mismatch surfaces the local fallback phase without result or ack")
    func sourceMismatchSurfacesLocalFallback() async throws {
        let api = FakeRemoteTranscriptionAPI(
            pollStates: [
                OpenCastRemoteTranscriptionJobStatus(
                    jobID: "job-fake-1",
                    state: .failed,
                    error: OpenCastRemoteTranscriptionJobError(code: .sourceMismatch)
                ),
            ]
        )
        let environment = try makeEnvironment(api: api, episodeID: "ep-mismatch")

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)

        #expect(await waitUntil { environment.store.phase == .mismatchLocalFallback })
        #expect(api.resultCallCount == 0)
        #expect(api.ackHashes.isEmpty)
        #expect(environment.transcriptions.record(for: "ep-mismatch") == nil)
        #expect(environment.store.references().isEmpty)
    }

    @Test("A server failure mid-transcription surfaces a visible terminal state with the local fallback")
    func serverFailureMidTranscriptionSurfacesTerminalState() async throws {
        let api = FakeRemoteTranscriptionAPI(
            pollStates: [
                OpenCastRemoteTranscriptionJobStatus(
                    jobID: "job-fake-1",
                    state: .transcribing,
                    progress: OpenCastRemoteTranscriptionJobProgress(chunksCompleted: 2, chunksTotal: 7)
                ),
                OpenCastRemoteTranscriptionJobStatus(
                    jobID: "job-fake-1",
                    state: .failed,
                    error: OpenCastRemoteTranscriptionJobError(code: .transcriptionFailed)
                ),
            ]
        )
        let environment = try makeEnvironment(api: api, episodeID: "ep-server-fail")

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)

        #expect(await waitUntil {
            environment.store.phase == .failed(.serverRejected(.transcriptionFailed))
        })
        #expect(api.resultCallCount == 0)
        #expect(api.ackHashes.isEmpty)

        // The surface renders a terminal failure with category copy and the
        // on-device path as the action — never the raw server string.
        let presentation = try #require(
            RemoteTranscriptionStatusPresentation.make(
                phase: environment.store.phase(for: "ep-server-fail")
            )
        )
        #expect(presentation.isTerminalFailure)
        #expect(presentation.offersLocalFallback)
        #expect(presentation.detail == RemoteTranscriptionFailureCategory.serverRejected(.transcriptionFailed).message)
    }

    @Test("An unreachable backend mid-poll surfaces the service-unavailable terminal state")
    func unreachableBackendMidPollSurfacesServiceUnavailable() async throws {
        let api = FakeRemoteTranscriptionAPI(
            pollStates: [
                OpenCastRemoteTranscriptionJobStatus(
                    jobID: "job-fake-1",
                    state: .transcribing,
                    progress: OpenCastRemoteTranscriptionJobProgress(chunksCompleted: 1, chunksTotal: 7)
                ),
            ],
            pollError: URLError(.notConnectedToInternet)
        )
        let environment = try makeEnvironment(api: api, episodeID: "ep-unreachable")

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)

        #expect(await waitUntil { environment.store.phase == .failed(.serviceUnavailable) })
        let presentation = try #require(
            RemoteTranscriptionStatusPresentation.make(
                phase: environment.store.phase(for: "ep-unreachable")
            )
        )
        #expect(presentation.isTerminalFailure)
        #expect(presentation.offersLocalFallback)
    }

    @Test("A detect run bails out of awaiting_credits as insufficient credits instead of parking")
    func detectRunBailsOutOfAwaitingCredits() async throws {
        let api = FakeRemoteTranscriptionAPI(
            pollStates: [
                OpenCastRemoteTranscriptionJobStatus(jobID: "job-fake-1", state: .awaitingCredits),
            ]
        )
        let environment = try makeEnvironment(api: api, episodeID: "ep-credits-detect")

        await #expect(throws: RemoteTranscriptionJobRunError.serverRejected(.insufficientCredits)) {
            _ = try await environment.runner.run(
                episode: environment.episode,
                enclosureURL: environment.episode.audioURL!,
                purpose: .adDetection,
                adAnalysis: RemoteTranscriptionJobRunner.AdAnalysisContext(
                    podcastID: environment.episode.podcastID,
                    episodeTitle: environment.episode.title,
                    podcastTitle: environment.episode.podcastTitle
                ),
                modelContext: environment.context,
                onEvent: { _ in }
            )
        }

        // Nothing is charged while the reservation is unfunded, so the job is
        // cancelled and the reference dropped — the device fallback is honest.
        #expect(api.cancelledJobIDs == ["job-fake-1"])
        #expect(environment.store.references().isEmpty)
    }

    @Test("Plain transcription keeps waiting through awaiting_credits and completes")
    func plainTranscriptionWaitsThroughAwaitingCredits() async throws {
        let identityData = Data("remote audio bytes ep-credits-wait".utf8)
        let identity = RemoteFixtures.identity(for: identityData, duration: 120)
        let result = RemoteFixtures.result(identity: identity, durationSeconds: 120.4)
        let api = FakeRemoteTranscriptionAPI(
            pollStates: [
                OpenCastRemoteTranscriptionJobStatus(jobID: "job-fake-1", state: .awaitingCredits),
                OpenCastRemoteTranscriptionJobStatus(jobID: "job-fake-1", state: .resultReady),
            ],
            resultResponse: OpenCastRemoteTranscriptionResultResponse(schemaVersion: 1, result: result)
        )
        let environment = try makeEnvironment(api: api, episodeID: "ep-credits-wait")
        var sawWaitingForCredits = false

        let outcome = try await environment.runner.run(
            episode: environment.episode,
            enclosureURL: environment.episode.audioURL!,
            purpose: .transcription,
            modelContext: environment.context,
            onEvent: { event in
                if case .waitingForCredits = event {
                    sawWaitingForCredits = true
                }
            }
        )

        #expect(sawWaitingForCredits)
        #expect(outcome.document.text == "Hello remote transcript.")
        #expect(api.cancelledJobIDs.isEmpty)
    }

    @Test("A transient poll blip is retried and the run still completes")
    func transientPollBlipIsRetried() async throws {
        let identityData = Data("remote audio bytes ep-poll-blip".utf8)
        let identity = RemoteFixtures.identity(for: identityData, duration: 120)
        let result = RemoteFixtures.result(identity: identity, durationSeconds: 120.4)
        let api = FakeRemoteTranscriptionAPI(
            pollStates: [
                OpenCastRemoteTranscriptionJobStatus(jobID: "job-fake-1", state: .resultReady),
            ],
            transientPollErrors: [URLError(.networkConnectionLost)],
            resultResponse: OpenCastRemoteTranscriptionResultResponse(schemaVersion: 1, result: result)
        )
        let environment = try makeEnvironment(
            api: api,
            episodeID: "ep-poll-blip",
            transportRetryDelays: [.zero]
        )

        let outcome = try await environment.runner.run(
            episode: environment.episode,
            enclosureURL: environment.episode.audioURL!,
            purpose: .transcription,
            modelContext: environment.context,
            onEvent: { _ in }
        )

        #expect(outcome.document.text == "Hello remote transcript.")
        #expect(api.cancelledJobIDs.isEmpty)
    }

    @Test("Transport give-up after create cancels a detect job and drops its reference")
    func transportGiveUpAbandonsDetectJob() async throws {
        let api = FakeRemoteTranscriptionAPI(
            pollStates: [
                OpenCastRemoteTranscriptionJobStatus(jobID: "job-fake-1", state: .transcribing),
            ],
            pollError: URLError(.notConnectedToInternet)
        )
        let environment = try makeEnvironment(api: api, episodeID: "ep-detect-unreachable")

        await #expect(throws: RemoteTranscriptionJobRunError.serviceUnavailable) {
            _ = try await environment.runner.run(
                episode: environment.episode,
                enclosureURL: environment.episode.audioURL!,
                purpose: .adDetection,
                adAnalysis: RemoteTranscriptionJobRunner.AdAnalysisContext(
                    podcastID: environment.episode.podcastID,
                    episodeTitle: environment.episode.title,
                    podcastTitle: environment.episode.podcastTitle
                ),
                modelContext: environment.context,
                onEvent: { _ in }
            )
        }

        // The cancel is best-effort and detached; the reference drop is
        // immediate so the offered device fallback never races a live job.
        #expect(await waitUntil { api.cancelledJobIDs == ["job-fake-1"] })
        #expect(environment.store.references().isEmpty)
    }

    @Test("Transport give-up keeps a plain transcription reference for re-attach")
    func transportGiveUpKeepsPlainTranscriptionReference() async throws {
        let api = FakeRemoteTranscriptionAPI(
            pollStates: [
                OpenCastRemoteTranscriptionJobStatus(jobID: "job-fake-1", state: .transcribing),
            ],
            pollError: URLError(.notConnectedToInternet)
        )
        let environment = try makeEnvironment(api: api, episodeID: "ep-plain-unreachable")

        await #expect(throws: RemoteTranscriptionJobRunError.serviceUnavailable) {
            _ = try await environment.runner.run(
                episode: environment.episode,
                enclosureURL: environment.episode.audioURL!,
                purpose: .transcription,
                modelContext: environment.context,
                onEvent: { _ in }
            )
        }

        // A retry re-attaches to the still-running job via the stable client
        // request ID, so the paid work is never abandoned.
        #expect(api.cancelledJobIDs.isEmpty)
        #expect(environment.store.references().isEmpty == false)
    }

    @Test("Cancel reaches the server and ends in the cancelled phase")
    func cancelReachesServerAndEndsCancelled() async throws {
        let api = FakeRemoteTranscriptionAPI(
            pollStates: [
                OpenCastRemoteTranscriptionJobStatus(
                    jobID: "job-fake-1",
                    state: .transcribing,
                    progress: OpenCastRemoteTranscriptionJobProgress(chunksCompleted: 0, chunksTotal: 7)
                ),
            ]
        )
        let environment = try makeEnvironment(api: api, episodeID: "ep-cancel")

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)
        #expect(await waitUntil {
            guard case let .processing(progress) = environment.store.phase else {
                return false
            }
            return progress.stage == .transcribing
                && progress.completedChunks == 0
                && progress.totalChunks == 7
        })

        environment.coordinator.cancel()

        #expect(await waitUntil { environment.store.phase == .cancelled })
        #expect(await waitUntil { api.cancelledJobIDs == ["job-fake-1"] })

        // Cancellation also ends visibly, with the on-device path offered.
        let presentation = try #require(
            RemoteTranscriptionStatusPresentation.make(
                phase: environment.store.phase(for: "ep-cancel")
            )
        )
        #expect(presentation.isTerminalFailure)
        #expect(presentation.offersLocalFallback)
    }

    @Test("Exact-upload fallback uploads every part and delivers the transcript")
    func exactUploadFallbackDeliversTranscript() async throws {
        let identityData = Data("remote audio bytes ep-upload".utf8)
        let identity = RemoteFixtures.identity(for: identityData, duration: 120)
        let result = RemoteFixtures.result(identity: identity, durationSeconds: 120.4)
        let api = FakeRemoteTranscriptionAPI(
            pollStates: [
                OpenCastRemoteTranscriptionJobStatus(jobID: "job-fake-1", state: .exactUploadRequired),
                OpenCastRemoteTranscriptionJobStatus(
                    jobID: "job-fake-1",
                    state: .transcribing,
                    progress: OpenCastRemoteTranscriptionJobProgress(chunksCompleted: 1, chunksTotal: 1)
                ),
                OpenCastRemoteTranscriptionJobStatus(jobID: "job-fake-1", state: .resultReady),
            ],
            resultResponse: OpenCastRemoteTranscriptionResultResponse(schemaVersion: 1, result: result),
            uploadScript: FakeRemoteTranscriptionAPI.UploadScript(
                partCount: 3,
                partSizeBytes: 10
            )
        )
        let transport = FakeUploadTransport()
        let environment = try makeEnvironment(
            api: api,
            episodeID: "ep-upload",
            uploadTransport: transport
        )

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)

        #expect(await waitUntil { environment.store.phase == .completed })
        #expect(api.uploadStartCount == 1)
        // Uniform parts with the exact remainder tail, all three PUT once.
        #expect(transport.putPartNumbers.sorted() == [1, 2, 3])
        #expect(transport.putFileSizes[1] == [10])
        #expect(transport.putFileSizes[2] == [10])
        #expect(transport.putFileSizes[3] == [Int(identityData.count) - 20])
        let completed = try #require(api.completedUploadParts.first)
        #expect(completed.map(\.partNumber) == [1, 2, 3])
        // ETags are unquoted before completion.
        #expect(completed.map(\.etag) == ["etag-1", "etag-2", "etag-3"])
        #expect(environment.transcriptions.document(for: "ep-upload") != nil)
    }

    @Test("A post-upload identity rejection surfaces its own failure copy")
    func uploadIdentityMismatchSurfacesFailure() async throws {
        let api = FakeRemoteTranscriptionAPI(
            pollStates: [
                OpenCastRemoteTranscriptionJobStatus(jobID: "job-fake-1", state: .exactUploadRequired),
                OpenCastRemoteTranscriptionJobStatus(
                    jobID: "job-fake-1",
                    state: .failed,
                    error: OpenCastRemoteTranscriptionJobError(code: .uploadIdentityMismatch)
                ),
            ],
            uploadScript: FakeRemoteTranscriptionAPI.UploadScript(partCount: 1, partSizeBytes: 64)
        )
        let transport = FakeUploadTransport()
        let environment = try makeEnvironment(
            api: api,
            episodeID: "ep-upload-mismatch",
            uploadTransport: transport
        )

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)

        #expect(await waitUntil {
            environment.store.phase == .failed(.serverRejected(.uploadIdentityMismatch))
        })
        let presentation = try #require(
            RemoteTranscriptionStatusPresentation.make(
                phase: environment.store.phase(for: "ep-upload-mismatch")
            )
        )
        #expect(presentation.isTerminalFailure)
        #expect(presentation.offersLocalFallback)
    }

    @Test("A 403 on a part refreshes the URL through upload/parts and re-PUTs the same part")
    func uploadPartRefreshesOn403() async throws {
        let identityData = Data("remote audio bytes ep-upload-403".utf8)
        let identity = RemoteFixtures.identity(for: identityData, duration: 120)
        let result = RemoteFixtures.result(identity: identity, durationSeconds: 120.4)
        let api = FakeRemoteTranscriptionAPI(
            pollStates: [
                OpenCastRemoteTranscriptionJobStatus(jobID: "job-fake-1", state: .exactUploadRequired),
                OpenCastRemoteTranscriptionJobStatus(jobID: "job-fake-1", state: .resultReady),
            ],
            resultResponse: OpenCastRemoteTranscriptionResultResponse(schemaVersion: 1, result: result),
            uploadScript: FakeRemoteTranscriptionAPI.UploadScript(partCount: 2, partSizeBytes: 16)
        )
        let transport = FakeUploadTransport(scriptedResults: [
            2: [RemoteTranscriptionUploadPartPutResult(statusCode: 403, etag: nil)],
        ])
        let environment = try makeEnvironment(
            api: api,
            episodeID: "ep-upload-403",
            uploadTransport: transport
        )

        environment.coordinator.start(episode: environment.episode, modelContext: environment.context)

        #expect(await waitUntil { environment.store.phase == .completed })
        // Part 2 was PUT twice — the 403, then the refreshed credential.
        #expect(transport.putPartNumbers.count(where: { $0 == 2 }) == 2)
        #expect(api.refreshedPartNumbers.contains([2]))
        let secondPutURL = try #require(transport.putURLStrings[2]?.last)
        #expect(secondPutURL.contains("refreshed"))
        #expect(api.completedUploadParts.first?.count == 2)
    }

    @Test("Missing audio URL fails immediately without any API traffic")
    func missingAudioURLFailsImmediately() async throws {
        let api = FakeRemoteTranscriptionAPI(pollStates: [
            OpenCastRemoteTranscriptionJobStatus(jobID: "job-fake-1", state: .created),
        ])
        let environment = try makeEnvironment(api: api, episodeID: "ep-no-audio")
        let episode = makeEpisode(episodeID: "ep-no-audio", audioURL: nil)

        environment.coordinator.start(episode: episode, modelContext: environment.context)

        #expect(environment.store.phase == .failed(.missingAudio))
        #expect(api.createRequests.isEmpty)
    }

    @Test("A completed transcript prevents a second remote transcription job")
    func completedTranscriptPreventsDuplicateRemoteJob() async throws {
        let api = FakeRemoteTranscriptionAPI(pollStates: [
            OpenCastRemoteTranscriptionJobStatus(jobID: "job-fake-1", state: .created),
        ])
        let environment = try makeEnvironment(api: api, episodeID: "ep-already-transcribed")
        let document = try EpisodeRemoteTranscriptMapper.document(
            from: RemoteFixtures.result(
                identity: environment.identity,
                durationSeconds: 120.4
            ),
            context: EpisodeRemoteTranscriptMapper.Context(
                episodeID: environment.episode.episodeID,
                podcastID: environment.episode.podcastID,
                sourceAudioURL: environment.episode.audioURL!,
                localIdentity: environment.identity,
                jobProvenanceToken: "job-existing"
            )
        )
        try await environment.transcriptions.importRemoteTranscript(
            document,
            modelContext: environment.context
        )

        environment.coordinator.start(
            episode: environment.episode,
            modelContext: environment.context
        )

        #expect(environment.transcriptions.hasCompletedTranscript(
            for: environment.episode.episodeID
        ))
        #expect(environment.store.phase == nil)
        #expect(api.createRequests.isEmpty)
    }

    @Test("A newer remote import supersedes the prior document only after commit")
    func newerRemoteImportSupersedesPriorDocument() async throws {
        let api = FakeRemoteTranscriptionAPI(pollStates: [
            OpenCastRemoteTranscriptionJobStatus(jobID: "job-fake-1", state: .created),
        ])
        let environment = try makeEnvironment(api: api, episodeID: "ep-supersede")
        let identity = environment.identity

        let first = try EpisodeRemoteTranscriptMapper.document(
            from: RemoteFixtures.result(identity: identity, durationSeconds: 120.4),
            context: EpisodeRemoteTranscriptMapper.Context(
                episodeID: "ep-supersede",
                podcastID: environment.episode.podcastID,
                sourceAudioURL: environment.episode.audioURL!,
                localIdentity: identity,
                jobProvenanceToken: "job-first"
            )
        )
        try await environment.transcriptions.importRemoteTranscript(first, modelContext: environment.context)
        let firstPath = try #require(
            environment.transcriptions.record(for: "ep-supersede")?.transcriptRelativePath
        )

        let second = try EpisodeRemoteTranscriptMapper.document(
            from: RemoteFixtures.result(
                identity: identity,
                durationSeconds: 120.4,
                pipelineVersion: "pass0-next"
            ),
            context: EpisodeRemoteTranscriptMapper.Context(
                episodeID: "ep-supersede",
                podcastID: environment.episode.podcastID,
                sourceAudioURL: environment.episode.audioURL!,
                localIdentity: identity,
                jobProvenanceToken: "job-second"
            )
        )
        try await environment.transcriptions.importRemoteTranscript(second, modelContext: environment.context)

        let record = try #require(environment.transcriptions.record(for: "ep-supersede"))
        let secondPath = try #require(record.transcriptRelativePath)
        #expect(secondPath != firstPath)
        let document = try #require(environment.transcriptions.document(for: "ep-supersede"))
        #expect(document.remotePipelineVersion == "pass0-next")
        #expect(document.remoteJobProvenanceToken == "job-second")
    }

    // MARK: Helpers

    private func makeEpisode(episodeID: String) -> EpisodeListItemSnapshot {
        makeEpisode(episodeID: episodeID, audioURL: "https://example.com/\(episodeID).mp3")
    }

    private func makeEpisode(episodeID: String, audioURL: String?) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: episodeID,
            podcastID: "https://example.com/feed.xml",
            podcastTitle: "Example Show",
            title: "Example Episode",
            summary: nil,
            publishedAt: nil,
            duration: 120,
            audioURL: audioURL,
            artworkURL: "https://example.com/art.jpg",
            artworkPreview: nil,
            guid: episodeID,
            cachedAt: .now
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastRemoteTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        return condition()
    }
}

// MARK: - Launch-argument UI fixtures

@MainActor
@Suite("Remote transcription UI fixtures")
struct RemoteTranscriptionUIFixtureTests {
    @Test("Parses the launch argument with and without an episode ID")
    func parsesLaunchArgument() {
        let plain = RemoteTranscriptionUIFixture.fromLaunchArguments(
            ["app", RemoteTranscriptionUIFixture.launchArgument, "transcribing"]
        )
        #expect(plain?.fixture == .transcribing)
        #expect(plain?.episodeID == RemoteTranscriptionUIFixture.defaultEpisodeID)

        let scoped = RemoteTranscriptionUIFixture.fromLaunchArguments(
            ["app", RemoteTranscriptionUIFixture.launchArgument, "mismatch:ep-9"]
        )
        #expect(scoped?.fixture == .mismatchLocalFallback)
        #expect(scoped?.episodeID == "ep-9")

        #expect(RemoteTranscriptionUIFixture.fromLaunchArguments(["app"]) == nil)
        #expect(RemoteTranscriptionUIFixture.fromLaunchArguments(
            ["app", RemoteTranscriptionUIFixture.launchArgument, "not-a-state"]
        ) == nil)
        #expect(RemoteTranscriptionUIFixture.fromLaunchArguments(
            ["app", RemoteTranscriptionUIFixture.launchArgument]
        ) == nil)
    }

    @Test("Every fixture drives the store into its UI state")
    func everyFixtureDrivesStoreState() {
        for fixture in RemoteTranscriptionUIFixture.allCases {
            let suiteName = "remote-fixture-tests-\(fixture.rawValue)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            let store = RemoteTranscriptionJobStore(defaults: defaults)

            fixture.apply(to: store, episodeID: "ep-fixture")

            #expect(store.balance?.availableSeconds == 33_959)
            switch fixture {
            case .devBalance:
                #expect(store.phase == nil)
            case .hashMatchInProgress:
                #expect(store.phase(for: "ep-fixture") == .verifying)
                #expect(store.hasActiveRequest)
            case .transcribing:
                #expect(store.phase(for: "ep-fixture") == .processing(
                    RemoteTranscriptionActiveProgress(
                        stage: .transcribing,
                        completedChunks: 3,
                        totalChunks: 7,
                        fractionCompleted: 3.0 / 7.0,
                        estimate: .onTrack(remainingSeconds: 52)
                    )
                ))
                #expect(store.hasActiveRequest)
            case .uploading:
                #expect(store.phase(for: "ep-fixture") == .uploadingExactCopy(completedParts: 2, totalParts: 5))
                #expect(store.hasActiveRequest)
            case .resultImported:
                #expect(store.phase(for: "ep-fixture") == .completed)
                #expect(!store.hasActiveRequest)
            case .mismatchLocalFallback:
                #expect(store.phase(for: "ep-fixture") == .mismatchLocalFallback)
                #expect(!store.hasActiveRequest)
            case .serverFailure:
                #expect(store.phase(for: "ep-fixture") == .failed(.serverRejected(.transcriptionFailed)))
                #expect(!store.hasActiveRequest)
            case .unreachableFailure:
                #expect(store.phase(for: "ep-fixture") == .failed(.serviceUnavailable))
                #expect(!store.hasActiveRequest)
            case .cancelled:
                #expect(store.phase(for: "ep-fixture") == .cancelled)
                #expect(!store.hasActiveRequest)
            }
            store.cancelActiveRequest()
        }
    }
}

// MARK: - Progress and ETA mapping

@MainActor
@Suite("Remote transcription progress mapping")
struct RemoteTranscriptionProgressMappingTests {
    @Test("Server processing states map to the three honest client stages")
    func stateMapping() throws {
        let tracker = RemoteTranscriptionProgressTracker()
        for state in [
            OpenCastRemoteTranscriptionJobState.sourceMatched,
            .probing,
            .reserved,
        ] {
            let progress = try #require(tracker.activeProgress(for: status(state: state)))
            #expect(progress.stage == .checkingAudioDetails)
        }
        for state in [
            OpenCastRemoteTranscriptionJobState.chunking,
            .transcribing,
        ] {
            let progress = try #require(tracker.activeProgress(for: status(state: state)))
            #expect(progress.stage == .transcribing)
        }
        let stitching = try #require(tracker.activeProgress(for: status(state: .stitching)))
        #expect(stitching.stage == .finalizing)
    }

    @Test("Rounded ETA buckets are stable at every boundary")
    func roundedETABoundaries() {
        #expect(RemoteTranscriptionEstimate.onTrack(remainingSeconds: 1).displayText == "Finishing up.")
        #expect(RemoteTranscriptionEstimate.onTrack(remainingSeconds: 14).displayText == "Finishing up.")
        #expect(RemoteTranscriptionEstimate.onTrack(remainingSeconds: 15).displayText == "About 20 seconds remaining.")
        #expect(RemoteTranscriptionEstimate.onTrack(remainingSeconds: 44).displayText == "About 40 seconds remaining.")
        #expect(RemoteTranscriptionEstimate.onTrack(remainingSeconds: 45).displayText == "About 1 minute remaining.")
        #expect(RemoteTranscriptionEstimate.onTrack(remainingSeconds: 89).displayText == "About 1 minute remaining.")
        #expect(RemoteTranscriptionEstimate.onTrack(remainingSeconds: 90).displayText == "About 2 minutes remaining.")
        #expect(RemoteTranscriptionEstimate.onTrack(remainingSeconds: 149).displayText == "About 2 minutes remaining.")
        #expect(RemoteTranscriptionEstimate.onTrack(remainingSeconds: 150).displayText == "About 3 minutes remaining.")
    }

    @Test("Queued and delayed states use service-aware copy")
    func exceptionalEstimateCopy() {
        #expect(RemoteTranscriptionEstimate(progress: OpenCastRemoteTranscriptionJobProgress(
            estimatedRemainingSeconds: 52,
            estimateStatus: .onTrack
        )) == .onTrack(remainingSeconds: 52))
        #expect(RemoteTranscriptionEstimate(progress: OpenCastRemoteTranscriptionJobProgress(
            estimatedRemainingSeconds: 52,
            estimateStatus: .queued
        )) == .queued(remainingSeconds: 52))
        #expect(RemoteTranscriptionEstimate(progress: OpenCastRemoteTranscriptionJobProgress(
            estimatedRemainingSeconds: nil,
            estimateStatus: .delayed
        )) == .delayed)
        #expect(
            RemoteTranscriptionEstimate.queued(remainingSeconds: 52).displayText
                == "Waiting for an open slot — about 1 minute remaining."
        )
        #expect(
            RemoteTranscriptionEstimate.delayed.displayText
                == "Taking longer than usual — still working"
        )
    }

    @Test("Fractions stay monotonic through a shrinking-total handoff and clamp server counts")
    func monotonicFractions() throws {
        let tracker = RemoteTranscriptionProgressTracker()
        let first = try #require(tracker.activeProgress(for: status(
            state: .chunking,
            completed: 3,
            total: 7
        )))
        let handoff = try #require(tracker.activeProgress(for: status(
            state: .transcribing,
            completed: 2,
            total: 5
        )))
        let clamped = try #require(tracker.activeProgress(for: status(
            state: .transcribing,
            completed: 9,
            total: 7
        )))
        #expect(first.fractionCompleted == 3.0 / 7.0)
        #expect(handoff.fractionCompleted == first.fractionCompleted)
        #expect(clamped.fractionCompleted == 1)
    }

    @Test("Legacy and unknown estimates safely fall back to indeterminate progress")
    func compatibilityFallbacks() throws {
        let tracker = RemoteTranscriptionProgressTracker()
        let legacy = try #require(tracker.activeProgress(for: status(state: .transcribing)))
        #expect(legacy.fractionCompleted == nil)
        #expect(legacy.estimate == nil)

        let unknown = OpenCastRemoteTranscriptionJobProgress(
            estimatedRemainingSeconds: 20,
            estimateStatus: .unknown("recalculating")
        )
        #expect(RemoteTranscriptionEstimate(progress: unknown) == nil)
    }

    private func status(
        state: OpenCastRemoteTranscriptionJobState,
        completed: Int? = nil,
        total: Int? = nil
    ) -> OpenCastRemoteTranscriptionJobStatus {
        OpenCastRemoteTranscriptionJobStatus(
            jobID: "job-progress",
            state: state,
            progress: completed == nil && total == nil
                ? nil
                : OpenCastRemoteTranscriptionJobProgress(
                    chunksCompleted: completed,
                    chunksTotal: total
                )
        )
    }
}

// MARK: - Status surface presentation

@MainActor
@Suite("Remote transcription status presentation")
struct RemoteTranscriptionStatusPresentationTests {
    @Test("Every terminal non-completed phase renders a failure with the local fallback")
    func terminalPhasesAlwaysRender() {
        let phases: [RemoteTranscriptionRequestPhase] = [
            .mismatchLocalFallback,
            .cancelled,
            .failed(.serverRejected(.transcriptionFailed)),
            .failed(.serverRejected(.internalError)),
            .failed(.serviceUnavailable),
            .failed(.downloadFailed),
            .failed(.resultInvalid),
            .failed(.missingAudio),
        ]
        for phase in phases {
            let presentation = RemoteTranscriptionStatusPresentation.make(phase: phase)
            #expect(presentation?.isTerminalFailure == true, "\(phase)")
            #expect(presentation?.offersLocalFallback == true, "\(phase)")
            #expect(presentation?.detail?.isEmpty == false, "\(phase)")
        }
    }

    @Test("Category copy never echoes raw wire strings")
    func categoryCopyNeverEchoesWireStrings() {
        let presentation = RemoteTranscriptionStatusPresentation.make(
            phase: .failed(.serverRejected(.unknown("weird_new_code")))
        )
        #expect(presentation?.detail?.contains("weird_new_code") == false)
    }

    @Test("Completed and idle hide the card; running phases show progress without the fallback")
    func nonTerminalMapping() {
        #expect(RemoteTranscriptionStatusPresentation.make(phase: nil) == nil)
        #expect(RemoteTranscriptionStatusPresentation.make(phase: .completed) == nil)

        let progress = RemoteTranscriptionActiveProgress(
            stage: .transcribing,
            completedChunks: 3,
            totalChunks: 7,
            fractionCompleted: 3.0 / 7.0,
            estimate: .onTrack(remainingSeconds: 52)
        )
        let running = RemoteTranscriptionStatusPresentation.make(
            phase: .processing(progress)
        )
        #expect(running?.isTerminalFailure == false)
        #expect(running?.offersLocalFallback == false)
        #expect(running?.detail == "Transcribing")
        #expect(running?.secondaryDetail == "About 1 minute remaining.")
        #expect(running?.progressFraction == 3.0 / 7.0)
        #expect(RemoteTranscriptionRequestPhase.processing(progress).displayText == "Transcribing")
    }
}
