import Foundation
import OpenCastTranscription
import OSLog

/// Exact-device upload engine (pass 2): drives one job's multipart upload of
/// the completed local download through presigned part URLs. Part-level
/// resume is the correctness mechanism — part state (number, ETag, attempts)
/// persists across relaunches and a re-run re-PUTs only missing parts on
/// fresh URLs. A 403 on a part is a credential refresh through the
/// authenticated `upload/parts` route, never a failure. At most two parts
/// are in flight; part files are deleted on completion, cancellation, and
/// terminal failure.
final class RemoteTranscriptionUploadSession {
    nonisolated private static let logger = Logger(
        subsystem: "com.connor.opencast",
        category: "RemoteTranscriptionUpload"
    )

    struct PartRecord: Codable, Equatable {
        var partNumber: Int
        var etag: String?
        var attempts: Int
    }

    struct PersistedState: Codable, Equatable {
        var uploadKeyID: String
        var partSizeBytes: Int64
        var partCount: Int
        var parts: [PartRecord]
    }

    enum UploadFailure: Error, Equatable {
        case partRejected(partNumber: Int, statusCode: Int)
        case missingETag(partNumber: Int)
        case invalidPartURL(partNumber: Int)
        case sourceFileUnreadable
    }

    static let maxConcurrentParts = 2
    private static let maxAttemptsPerPart = 3
    /// Presigned URLs this close to expiry are refreshed before use.
    private static let urlExpiryMarginSeconds: Int64 = 30

    private let jobID: String
    private let sourceFileURL: URL
    private let api: any RemoteTranscriptionAPI
    private let transport: any RemoteTranscriptionUploadTransport
    private let defaults: UserDefaults

    private(set) var state: PersistedState?

    init(
        jobID: String,
        sourceFileURL: URL,
        api: any RemoteTranscriptionAPI,
        transport: any RemoteTranscriptionUploadTransport,
        defaults: UserDefaults = .standard
    ) {
        self.jobID = jobID
        self.sourceFileURL = sourceFileURL
        self.api = api
        self.transport = transport
        self.defaults = defaults
    }

    static func defaultsKey(jobID: String) -> String {
        "remoteTranscription.upload.\(jobID)"
    }

    private var partDirectory: URL {
        URL.cachesDirectory.appending(path: "RemoteTranscriptionUpload/\(jobID)", directoryHint: .isDirectory)
    }

    /// Uploads every missing part and completes the multipart upload.
    /// `progress` reports (completed parts, total parts) as parts land.
    func run(progress: ((Int, Int) -> Void)? = nil) async throws {
        let grant = try await api.uploadStart(jobID: jobID, forBackground: false)
        var restored = restoredState()
        if restored?.uploadKeyID != grant.uploadKeyID
            || restored?.partCount != grant.partCount
            || restored?.partSizeBytes != grant.partSizeBytes {
            // A new server-side upload (or changed geometry) invalidates any
            // prior part bookkeeping; parts must be byte-identical.
            restored = nil
        }
        let initial = restored ?? PersistedState(
            uploadKeyID: grant.uploadKeyID,
            partSizeBytes: grant.partSizeBytes,
            partCount: grant.partCount,
            parts: (1...max(grant.partCount, 1)).map {
                PartRecord(partNumber: $0, etag: nil, attempts: 0)
            }
        )
        state = initial
        persist()
        var grants: [Int: OpenCastRemoteTranscriptionUploadPartGrant] = [:]
        for part in grant.parts {
            grants[part.partNumber] = part
        }

        progress?(completedPartCount, initial.partCount)
        let pending = initial.parts.filter { $0.etag == nil }.map(\.partNumber)

        try await withThrowingTaskGroup(of: (partNumber: Int, etag: String).self) { group in
            var nextIndex = 0
            while nextIndex < pending.count, nextIndex < Self.maxConcurrentParts {
                let partNumber = pending[nextIndex]
                let initialGrant = grants[partNumber]
                group.addTask { try await self.uploadOnePart(partNumber: partNumber, initialGrant: initialGrant) }
                nextIndex += 1
            }
            while let completed = try await group.next() {
                markCompleted(partNumber: completed.partNumber, etag: completed.etag)
                progress?(completedPartCount, initial.partCount)
                if nextIndex < pending.count {
                    let partNumber = pending[nextIndex]
                    let initialGrant = grants[partNumber]
                    group.addTask { try await self.uploadOnePart(partNumber: partNumber, initialGrant: initialGrant) }
                    nextIndex += 1
                }
            }
        }

        let parts = (state ?? initial).parts.compactMap { record in
            record.etag.map {
                OpenCastRemoteTranscriptionUploadCompletedPart(partNumber: record.partNumber, etag: $0)
            }
        }
        _ = try await api.uploadComplete(jobID: jobID, parts: parts)
        transport.finishTasksAndInvalidate()
        cleanUp()
    }

    /// Cancels in-flight part tasks and deletes part files and persisted
    /// state. Server-side abort happens through the job cancel route.
    func cancelAndCleanUp() async {
        await transport.cancelOutstandingTasks()
        cleanUp()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: partDirectory)
        defaults.removeObject(forKey: Self.defaultsKey(jobID: jobID))
    }

    // MARK: - Per-part upload

    private func uploadOnePart(
        partNumber: Int,
        initialGrant: OpenCastRemoteTranscriptionUploadPartGrant?
    ) async throws -> (partNumber: Int, etag: String) {
        var grant = initialGrant
        while true {
            try Task.checkCancellation()
            let current: OpenCastRemoteTranscriptionUploadPartGrant
            if let grant, grant.expiresAt > nowEpochSeconds() + Self.urlExpiryMarginSeconds {
                current = grant
            } else {
                current = try await refreshedGrant(partNumber: partNumber)
            }
            grant = current
            guard let url = URL(string: current.url) else {
                throw UploadFailure.invalidPartURL(partNumber: partNumber)
            }

            let fileURL = try await partFile(partNumber: partNumber)
            let result: RemoteTranscriptionUploadPartPutResult
            do {
                result = try await transport.uploadPart(
                    partNumber: partNumber,
                    fileURL: fileURL,
                    to: url
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                let attempts = recordFailedAttempt(partNumber: partNumber)
                let urlErrorCode = (error as? URLError)?.errorCode ?? 0
                Self.logger.error(
                    "part PUT transport error part=\(partNumber) attempt=\(attempts) url_error=\(urlErrorCode)"
                )
                if attempts >= Self.maxAttemptsPerPart {
                    throw error
                }
                try await Task.sleep(for: .seconds(2))
                grant = nil
                continue
            }
            if (200..<300).contains(result.statusCode) {
                if let etag = result.etag {
                    return (partNumber, etag.replacing("\"", with: ""))
                }
                let attempts = recordFailedAttempt(partNumber: partNumber)
                if attempts >= Self.maxAttemptsPerPart {
                    throw UploadFailure.missingETag(partNumber: partNumber)
                }
                try await Task.sleep(for: .seconds(2))
                grant = nil
                continue
            }

            let attempts = recordFailedAttempt(partNumber: partNumber)
            if attempts >= Self.maxAttemptsPerPart {
                throw UploadFailure.partRejected(partNumber: partNumber, statusCode: result.statusCode)
            }
            if result.statusCode == 403 {
                // Expired credential: refresh and re-PUT the same part.
                grant = nil
                continue
            }
            try await Task.sleep(for: .seconds(2))
            grant = nil
        }
    }

    private func refreshedGrant(
        partNumber: Int
    ) async throws -> OpenCastRemoteTranscriptionUploadPartGrant {
        let response = try await api.uploadParts(
            jobID: jobID,
            partNumbers: [partNumber],
            forBackground: false
        )
        guard let grant = response.parts.first(where: { $0.partNumber == partNumber }) else {
            throw UploadFailure.invalidPartURL(partNumber: partNumber)
        }
        return grant
    }

    /// Slices the part's exact byte range from the completed download into a
    /// temporary per-part file (background upload tasks require files).
    private func partFile(partNumber: Int) async throws -> URL {
        guard let state else {
            throw UploadFailure.sourceFileUnreadable
        }
        let directory = partDirectory
        let partURL = directory.appending(path: "part-\(partNumber).bin")
        let offset = Int64(partNumber - 1) * state.partSizeBytes
        let length = state.partSizeBytes
        let source = sourceFileURL
        return try await Self.writePartFile(
            source: source,
            to: partURL,
            in: directory,
            offset: offset,
            maxLength: length
        )
    }

    @concurrent
    nonisolated private static func writePartFile(
        source: URL,
        to partURL: URL,
        in directory: URL,
        offset: Int64,
        maxLength: Int64
    ) async throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if manager.fileExists(atPath: partURL.path) {
            return partURL
        }
        guard let handle = try? FileHandle(forReadingFrom: source) else {
            throw UploadFailure.sourceFileUnreadable
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: Int(maxLength)), data.isEmpty == false else {
            throw UploadFailure.sourceFileUnreadable
        }
        try data.write(to: partURL, options: .atomic)
        return partURL
    }

    // MARK: - Part state

    private var completedPartCount: Int {
        state?.parts.count(where: { $0.etag != nil }) ?? 0
    }

    private func markCompleted(partNumber: Int, etag: String) {
        guard var state else {
            return
        }
        if let index = state.parts.firstIndex(where: { $0.partNumber == partNumber }) {
            state.parts[index].etag = etag
        }
        self.state = state
        persist()
    }

    private func recordFailedAttempt(partNumber: Int) -> Int {
        guard var state else {
            return Self.maxAttemptsPerPart
        }
        guard let index = state.parts.firstIndex(where: { $0.partNumber == partNumber }) else {
            return Self.maxAttemptsPerPart
        }
        state.parts[index].attempts += 1
        self.state = state
        persist()
        return state.parts[index].attempts
    }

    private func restoredState() -> PersistedState? {
        guard let data = defaults.data(forKey: Self.defaultsKey(jobID: jobID)) else {
            return nil
        }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    private func persist() {
        guard let state, let data = try? JSONEncoder().encode(state) else {
            return
        }
        defaults.set(data, forKey: Self.defaultsKey(jobID: jobID))
    }

    nonisolated private func nowEpochSeconds() -> Int64 {
        Int64(Date.now.timeIntervalSince1970)
    }
}
