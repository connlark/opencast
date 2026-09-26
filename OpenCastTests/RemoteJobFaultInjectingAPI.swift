import Foundation
import OpenCastTranscription
@testable import OpenCast

/// Deterministic fake of the remote transcription worker with a server-side
/// ledger and named fault points, so recovery tests can script "the request
/// never left" separately from "the server accepted it and the response was
/// lost" without any wall-clock timing.
///
/// The ledger mirrors the Worker contract the client relies on: a repeated
/// `clientRequestID` create attaches to the existing job instead of minting
/// another; `/result` and `/ack` are refused (409) outside `result_ready` /
/// `delivered`, and a delivered result moves the job to `delivered`; an ack
/// on an acknowledged job and a cancel on a terminal job are idempotent
/// status reads; a cancel or ack that reached the server changes the job's
/// truth even when its response is lost, and a later poll reports that
/// truth ahead of any scripted state. Every call is recorded in order.
final class RemoteJobFaultInjectingAPI: RemoteTranscriptionAPI, @unchecked Sendable {
    enum Leg: Hashable, Sendable {
        case bootstrap
        case create
        case source
        case poll
        case result
        case ack
        case cancel
        case uploadStart
        case uploadParts
        case uploadComplete
    }

    enum FaultMode {
        /// The request never leaves the process; server state is untouched.
        case neverLeaves(any Error)
        /// The server processed the request; the client loses the response.
        case acceptedResponseLost(any Error)
        /// The request is held until the gate opens, then proceeds normally.
        case delayed(Gate)
        /// A local leg (App Attest, keychain, decode) fails before any
        /// request is built; server state is untouched.
        case localFailure(any Error)
        /// A landed HTTP error; on create the server rolled back or never
        /// wrote a mapping.
        case landed(RemoteTranscriptionHTTPError)
    }

    /// A resumable barrier with no timer: waiters suspend until `release()`.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var isReleased: Bool {
            lock.withLock { released }
        }

        func release() {
            let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
                released = true
                defer { waiters.removeAll() }
                return waiters
            }
            for waiter in pending {
                waiter.resume()
            }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let shouldResume: Bool = lock.withLock {
                    if released {
                        return true
                    }
                    waiters.append(continuation)
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        }
    }

    /// One recorded API call, in call order.
    struct TrafficEntry: Equatable, Sendable {
        let leg: Leg
        let clientRequestID: String?
        let jobID: String?
        /// False when the request never left the process.
        let reachedServer: Bool
        /// False when the server processed the request but the client lost
        /// the response.
        let responseDelivered: Bool
    }

    struct UploadScript: Sendable {
        var partCount: Int
        var partSizeBytes: Int64
    }

    private struct Fault {
        let leg: Leg
        let mode: FaultMode
        var remaining: Int
    }

    private enum FaultOutcome {
        case proceed
        case fail(any Error, reachedServer: Bool, responseDelivered: Bool, appliesServerEffect: Bool)
    }

    private let lock = NSLock()
    private var faults: [Fault] = []
    private var nextJobNumber = 1

    // Server ledger.
    private var jobIDsByClientRequestID: [String: String] = [:]
    private var jobStates: [String: OpenCastRemoteTranscriptionJobState] = [:]
    private var pollScriptsByJobID: [String: [OpenCastRemoteTranscriptionJobStatus]] = [:]

    // Scripts.
    private let pollScript: [OpenCastRemoteTranscriptionJobStatus]
    private let resultResponse: OpenCastRemoteTranscriptionResultResponse?
    private let uploadScript: UploadScript?

    // Recorded traffic; read through the locked accessors below.
    private var storedTraffic: [TrafficEntry] = []
    private var storedCreateRequests: [OpenCastRemoteTranscriptionJobCreateRequest] = []
    private var storedReportedIdentities: [OpenCastRemoteTranscriptionSourceIdentity] = []
    private var storedAckHashes: [String?] = []
    private var storedMintedJobIDs: [String] = []
    private var storedUploadStartCount = 0
    private var storedRefreshedPartNumbers: [[Int]] = []
    private var storedCompletedUploadParts: [[OpenCastRemoteTranscriptionUploadCompletedPart]] = []

    /// `pollScript` states are served in order per job and the last one
    /// repeats; their `jobID` is rewritten to the job being polled.
    init(
        pollScript: [OpenCastRemoteTranscriptionJobStatus] = [
            OpenCastRemoteTranscriptionJobStatus(jobID: "", state: .created),
        ],
        resultResponse: OpenCastRemoteTranscriptionResultResponse? = nil,
        uploadScript: UploadScript? = nil
    ) {
        self.pollScript = pollScript
        self.resultResponse = resultResponse
        self.uploadScript = uploadScript
    }

    // MARK: Recorded traffic (snapshots taken under the lock)

    var traffic: [TrafficEntry] { lock.withLock { storedTraffic } }
    /// The legs that reached the server, in order.
    var callSequence: [Leg] { traffic.filter(\.reachedServer).map(\.leg) }
    var createCalls: [TrafficEntry] { traffic.filter { $0.leg == .create } }
    var pollCalls: [TrafficEntry] { traffic.filter { $0.leg == .poll } }
    var resultCalls: [TrafficEntry] { traffic.filter { $0.leg == .result } }
    var ackCalls: [TrafficEntry] { traffic.filter { $0.leg == .ack } }
    var cancelCalls: [TrafficEntry] { traffic.filter { $0.leg == .cancel } }
    var createRequests: [OpenCastRemoteTranscriptionJobCreateRequest] { lock.withLock { storedCreateRequests } }
    var reportedIdentities: [OpenCastRemoteTranscriptionSourceIdentity] { lock.withLock { storedReportedIdentities } }
    var ackHashes: [String?] { lock.withLock { storedAckHashes } }
    var mintedJobIDs: [String] { lock.withLock { storedMintedJobIDs } }
    var uploadStartCount: Int { lock.withLock { storedUploadStartCount } }
    var refreshedPartNumbers: [[Int]] { lock.withLock { storedRefreshedPartNumbers } }
    var completedUploadParts: [[OpenCastRemoteTranscriptionUploadCompletedPart]] { lock.withLock { storedCompletedUploadParts } }

    // MARK: Fault points

    /// Queues a fault for `leg`, consumed once per matching call (`times`
    /// controls how many calls it covers). Faults on the same leg fire in
    /// injection order.
    func inject(_ mode: FaultMode, at leg: Leg, times: Int = 1) {
        lock.withLock { faults.append(Fault(leg: leg, mode: mode, remaining: times)) }
    }

    private func takeFault(_ leg: Leg) -> FaultMode? {
        lock.withLock {
            guard let index = faults.firstIndex(where: { $0.leg == leg && $0.remaining > 0 }) else {
                return nil
            }
            faults[index].remaining -= 1
            return faults[index].mode
        }
    }

    private func applyFault(_ leg: Leg) async -> FaultOutcome {
        guard let mode = takeFault(leg) else {
            return .proceed
        }
        switch mode {
        case .neverLeaves(let error), .localFailure(let error):
            return .fail(error, reachedServer: false, responseDelivered: false, appliesServerEffect: false)
        case .acceptedResponseLost(let error):
            return .fail(error, reachedServer: true, responseDelivered: false, appliesServerEffect: true)
        case .landed(let error):
            return .fail(error, reachedServer: true, responseDelivered: true, appliesServerEffect: false)
        case .delayed(let gate):
            await gate.wait()
            return .proceed
        }
    }

    // MARK: Ledger queries and seeds

    /// The job the server mapped a client request ID to, if a create for it
    /// ever reached the server.
    func serverJobID(forClientRequestID clientRequestID: String) -> String? {
        lock.withLock { jobIDsByClientRequestID[clientRequestID] }
    }

    func serverState(of jobID: String) -> OpenCastRemoteTranscriptionJobState? {
        lock.withLock { jobStates[jobID] }
    }

    /// Seeds a job as if an earlier process created it, for relaunch,
    /// parked and death-after-import fixtures.
    func seedServerJob(
        clientRequestID: String,
        jobID: String,
        state: OpenCastRemoteTranscriptionJobState
    ) {
        lock.withLock {
            jobIDsByClientRequestID[clientRequestID] = jobID
            jobStates[jobID] = state
            storedMintedJobIDs.append(jobID)
        }
    }

    // MARK: Server effects (state rules mirror the Worker)

    private func serverCreate(clientRequestID: String) -> (jobID: String, state: OpenCastRemoteTranscriptionJobState) {
        lock.withLock {
            if let existing = jobIDsByClientRequestID[clientRequestID] {
                return (existing, jobStates[existing] ?? .created)
            }
            let jobID = "job-fake-\(nextJobNumber)"
            nextJobNumber += 1
            jobIDsByClientRequestID[clientRequestID] = jobID
            jobStates[jobID] = .created
            storedMintedJobIDs.append(jobID)
            return (jobID, .created)
        }
    }

    private func serverPoll(jobID: String) -> Result<OpenCastRemoteTranscriptionJobStatus, RemoteTranscriptionHTTPError> {
        lock.withLock {
            guard let ledgerState = jobStates[jobID] else {
                return .failure(Self.notFound)
            }
            // A cancel or ack that reached the server, or a delivered
            // result, is the truth from then on, whatever the script says.
            if ledgerState.isTerminal || ledgerState == .delivered {
                return .success(OpenCastRemoteTranscriptionJobStatus(jobID: jobID, state: ledgerState))
            }
            var queue = pollScriptsByJobID[jobID] ?? pollScript
            var next = queue.count > 1 ? queue.removeFirst() : queue[0]
            pollScriptsByJobID[jobID] = queue
            next.jobID = jobID
            jobStates[jobID] = next.state
            return .success(next)
        }
    }

    private func serverResult(jobID: String) -> Result<OpenCastRemoteTranscriptionResultResponse, RemoteTranscriptionHTTPError> {
        lock.withLock {
            guard let state = jobStates[jobID] else {
                return .failure(Self.notFound)
            }
            guard state == .resultReady || state == .delivered else {
                return .failure(Self.invalidRequest)
            }
            guard let resultResponse else {
                return .failure(RemoteTranscriptionHTTPError(statusCode: 410, code: "internal_error", detail: nil))
            }
            jobStates[jobID] = .delivered
            return .success(resultResponse)
        }
    }

    private func serverAck(jobID: String) -> Result<OpenCastRemoteTranscriptionJobState, RemoteTranscriptionHTTPError> {
        lock.withLock {
            guard let state = jobStates[jobID] else {
                return .failure(Self.notFound)
            }
            switch state {
            case .acknowledged:
                return .success(.acknowledged)
            case .resultReady, .delivered:
                jobStates[jobID] = .acknowledged
                return .success(.acknowledged)
            default:
                return .failure(Self.invalidRequest)
            }
        }
    }

    private func serverCancel(jobID: String) -> Result<OpenCastRemoteTranscriptionJobState, RemoteTranscriptionHTTPError> {
        lock.withLock {
            guard let state = jobStates[jobID] else {
                return .failure(Self.notFound)
            }
            if state.isTerminal {
                return .success(state)
            }
            jobStates[jobID] = .cancelled
            return .success(.cancelled)
        }
    }

    private static let notFound = RemoteTranscriptionHTTPError(statusCode: 404, code: "job_not_found", detail: nil)
    private static let invalidRequest = RemoteTranscriptionHTTPError(statusCode: 409, code: "invalid_request", detail: nil)

    private func status(jobID: String, state: OpenCastRemoteTranscriptionJobState) -> OpenCastRemoteTranscriptionJobResponse {
        OpenCastRemoteTranscriptionJobResponse(
            schemaVersion: 1,
            job: OpenCastRemoteTranscriptionJobStatus(jobID: jobID, state: state)
        )
    }

    private func record(
        _ leg: Leg,
        clientRequestID: String? = nil,
        jobID: String?,
        reachedServer: Bool = true,
        responseDelivered: Bool = true
    ) {
        let entry = TrafficEntry(
            leg: leg,
            clientRequestID: clientRequestID,
            jobID: jobID,
            reachedServer: reachedServer,
            responseDelivered: responseDelivered
        )
        lock.withLock { storedTraffic.append(entry) }
    }

    /// Records a landed server refusal and returns it for throwing.
    private func refuse(_ leg: Leg, jobID: String, _ error: RemoteTranscriptionHTTPError) -> RemoteTranscriptionHTTPError {
        record(leg, jobID: jobID)
        return error
    }

    // MARK: RemoteTranscriptionAPI

    func bootstrap() async throws -> OpenCastRemoteTranscriptionBootstrapResponse {
        if case let .fail(error, reached, delivered, _) = await applyFault(.bootstrap) {
            record(.bootstrap, jobID: nil, reachedServer: reached, responseDelivered: delivered)
            throw error
        }
        record(.bootstrap, jobID: nil)
        return OpenCastRemoteTranscriptionBootstrapResponse(
            schemaVersion: 1,
            accountID: "acct-fake",
            balance: OpenCastRemoteTranscriptionBalance(availableSeconds: 36_000, reservedSeconds: 0)
        )
    }

    func createJob(
        _ request: OpenCastRemoteTranscriptionJobCreateRequest
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        lock.withLock { storedCreateRequests.append(request) }
        let clientRequestID = request.clientRequestID
        if case let .fail(error, reached, delivered, applies) = await applyFault(.create) {
            let jobID = applies ? serverCreate(clientRequestID: clientRequestID).jobID : nil
            record(.create, clientRequestID: clientRequestID, jobID: jobID, reachedServer: reached, responseDelivered: delivered)
            throw error
        }
        let (jobID, state) = serverCreate(clientRequestID: clientRequestID)
        record(.create, clientRequestID: clientRequestID, jobID: jobID)
        return status(jobID: jobID, state: state)
    }

    func reportSource(
        jobID: String,
        identity: OpenCastRemoteTranscriptionSourceIdentity
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        if case let .fail(error, reached, delivered, applies) = await applyFault(.source) {
            if applies {
                lock.withLock { storedReportedIdentities.append(identity) }
            }
            record(.source, jobID: jobID, reachedServer: reached, responseDelivered: delivered)
            throw error
        }
        lock.withLock { storedReportedIdentities.append(identity) }
        record(.source, jobID: jobID)
        return status(jobID: jobID, state: .sourceMatched)
    }

    func poll(jobID: String) async throws -> OpenCastRemoteTranscriptionPollResponse {
        if case let .fail(error, reached, delivered, _) = await applyFault(.poll) {
            record(.poll, jobID: jobID, reachedServer: reached, responseDelivered: delivered)
            throw error
        }
        switch serverPoll(jobID: jobID) {
        case .success(let job):
            record(.poll, jobID: jobID)
            return OpenCastRemoteTranscriptionPollResponse(schemaVersion: 1, job: job, pollAfterSeconds: 0)
        case .failure(let error):
            throw refuse(.poll, jobID: jobID, error)
        }
    }

    func result(jobID: String) async throws -> OpenCastRemoteTranscriptionResultResponse {
        if case let .fail(error, reached, delivered, applies) = await applyFault(.result) {
            if applies {
                _ = serverResult(jobID: jobID)
            }
            record(.result, jobID: jobID, reachedServer: reached, responseDelivered: delivered)
            throw error
        }
        switch serverResult(jobID: jobID) {
        case .success(let response):
            record(.result, jobID: jobID)
            return response
        case .failure(let error):
            throw refuse(.result, jobID: jobID, error)
        }
    }

    func ack(
        jobID: String,
        normalizedTranscriptSHA256: String?
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        if case let .fail(error, reached, delivered, applies) = await applyFault(.ack) {
            if applies {
                _ = serverAck(jobID: jobID)
            }
            record(.ack, jobID: jobID, reachedServer: reached, responseDelivered: delivered)
            throw error
        }
        switch serverAck(jobID: jobID) {
        case .success(let state):
            lock.withLock { storedAckHashes.append(normalizedTranscriptSHA256) }
            record(.ack, jobID: jobID)
            return status(jobID: jobID, state: state)
        case .failure(let error):
            throw refuse(.ack, jobID: jobID, error)
        }
    }

    func cancel(jobID: String) async throws -> OpenCastRemoteTranscriptionJobResponse {
        if case let .fail(error, reached, delivered, applies) = await applyFault(.cancel) {
            if applies {
                _ = serverCancel(jobID: jobID)
            }
            record(.cancel, jobID: jobID, reachedServer: reached, responseDelivered: delivered)
            throw error
        }
        switch serverCancel(jobID: jobID) {
        case .success(let state):
            record(.cancel, jobID: jobID)
            return status(jobID: jobID, state: state)
        case .failure(let error):
            throw refuse(.cancel, jobID: jobID, error)
        }
    }

    func uploadStart(
        jobID: String,
        forBackground: Bool
    ) async throws -> OpenCastRemoteTranscriptionUploadGrantResponse {
        guard let uploadScript else {
            throw refuse(.uploadStart, jobID: jobID, Self.invalidRequest)
        }
        lock.withLock { storedUploadStartCount += 1 }
        record(.uploadStart, jobID: jobID)
        return grantResponse(script: uploadScript, partNumbers: Array(1...uploadScript.partCount))
    }

    func uploadParts(
        jobID: String,
        partNumbers: [Int],
        forBackground: Bool
    ) async throws -> OpenCastRemoteTranscriptionUploadGrantResponse {
        guard let uploadScript else {
            throw refuse(.uploadParts, jobID: jobID, Self.invalidRequest)
        }
        lock.withLock { storedRefreshedPartNumbers.append(partNumbers) }
        record(.uploadParts, jobID: jobID)
        return grantResponse(script: uploadScript, partNumbers: partNumbers, refreshed: true)
    }

    func uploadComplete(
        jobID: String,
        parts: [OpenCastRemoteTranscriptionUploadCompletedPart]
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        lock.withLock { storedCompletedUploadParts.append(parts) }
        record(.uploadComplete, jobID: jobID)
        return status(jobID: jobID, state: .sourceMatched)
    }

    func redeem(transactionJWS: String) async throws -> OpenCastRemoteTranscriptionRedeemResponse {
        throw RemoteTranscriptionHTTPError(statusCode: 503, code: "feature_disabled", detail: nil)
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
}
