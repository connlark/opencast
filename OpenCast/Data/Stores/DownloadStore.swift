import Foundation
import Observation
import OpenCastCore
import OpenCastTranscription
import SwiftData

@Observable
final class DownloadStore {
    static let autoDeletePlayedEpisodesPreferenceKey = "downloads.autoDeletePlayedEpisodes"

    // The index rebuilds on every mutation (didSet), so per-row lookups stay
    // O(1) and can never go stale (house precedent:
    // LibraryStore.episodeIndexByID). Mutations are rare; lookups run in
    // every episode-row body.
    private(set) var records: [EpisodeDownloadRecord] = [] {
        didSet {
            // Keep-first mirrors the replaced `records.first` lookup while
            // startup duplicate repair can still hold transient twins.
            recordsByEpisodeID = Dictionary(
                records.map { ($0.episodeID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }
    @ObservationIgnored private var recordsByEpisodeID: [String: EpisodeDownloadRecord] = [:]
    private(set) var lastErrorMessage: String?
    private(set) var autoDeletesPlayedDownloads = false
    /// Episode-ID groups that held more than one record and were collapsed to
    /// a proven survivor, cumulative for this process (startup repair plus
    /// migration collisions). Diagnostics-only; never names episodes.
    private(set) var duplicateRepairCount = 0
    private var lastErrorEpisodeID: String?
    // Live byte progress never touches the SwiftData record: per-tick record
    // writes get autosaved, and every save re-enters the persistent-history →
    // remote-change → synced-reload cascade. Records carry bytes only at
    // committed state transitions (pause/complete/fail).
    private var liveByteProgressByEpisodeID: [String: DownloadByteProgress] = [:]

    @ObservationIgnored private let downloader: any EpisodeAudioDownloading
    @ObservationIgnored private let fileStore: EpisodeDownloadFileStore
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var downloadTaskTokens: [String: String] = [:]
    @ObservationIgnored private var progressCheckpoints: [String: DownloadProgressCheckpoint] = [:]
    @ObservationIgnored private var pauseRequestedEpisodeIDs: Set<String> = []
    @ObservationIgnored private let stateChanges = StoreChangeNotifier()

    private static let minimumProgressPublicationInterval: TimeInterval = 0.25

    init(
        downloader: any EpisodeAudioDownloading = URLSessionEpisodeAudioDownloader(),
        fileStore: EpisodeDownloadFileStore = EpisodeDownloadFileStore()
    ) {
        self.downloader = downloader
        self.fileStore = fileStore
    }

    var completedDownloadCount: Int {
        records.count { $0.state == .completed }
    }

    var completedDownloadByteCount: Int64 {
        records
            .filter { $0.state == .completed }
            .reduce(0) { $0 + max($1.bytesReceived, 0) }
    }

    var failedOrMissingRecords: [EpisodeDownloadRecord] {
        records.filter { $0.state == .failed || $0.state == .missing }
    }

    var activeDownloadCount: Int {
        records.count { $0.state == .downloading || $0.state == .paused }
    }

    func load(modelContext: ModelContext) async {
        var firstError: (any Error)?
        do {
            try await reconcile(modelContext: modelContext)
        } catch {
            firstError = error
        }
        do {
            try reload(modelContext: modelContext)
        } catch {
            firstError = firstError ?? error
        }
        do {
            autoDeletesPlayedDownloads = try storedAutoDeletePreference(modelContext: modelContext)
        } catch {
            firstError = firstError ?? error
        }

        if let firstError {
            recordFailure(firstError)
        } else {
            lastErrorMessage = nil
            lastErrorEpisodeID = nil
        }
    }

    @discardableResult
    func setAutoDeletesPlayedDownloads(
        _ isEnabled: Bool,
        modelContext: ModelContext
    ) -> Bool {
        guard autoDeletesPlayedDownloads != isEnabled else {
            return true
        }

        let previousValue = autoDeletesPlayedDownloads
        autoDeletesPlayedDownloads = isEnabled
        do {
            try LocalPreferenceRecord.upsert(
                key: Self.autoDeletePlayedEpisodesPreferenceKey,
                value: isEnabled.description,
                modelContext: modelContext
            )
            try modelContext.save()
            lastErrorMessage = nil
            return true
        } catch {
            autoDeletesPlayedDownloads = previousValue
            recordFailure(error)
            return false
        }
    }

    func record(for episodeID: String) -> EpisodeDownloadRecord? {
        recordsByEpisodeID[episodeID]
    }

    /// Byte progress for display: the transient live value while a download is
    /// running, otherwise the record's last committed bytes.
    func byteProgress(for episodeID: String) -> DownloadByteProgress? {
        guard let record = record(for: episodeID) else {
            return nil
        }

        if record.state == .downloading, let live = liveByteProgressByEpisodeID[episodeID] {
            return live
        }
        return DownloadByteProgress(
            bytesReceived: max(record.bytesReceived, 0),
            bytesExpected: record.bytesExpected
        )
    }

    func lastErrorMessage(for episodeID: String) -> String? {
        guard lastErrorEpisodeID == episodeID else {
            return nil
        }

        return lastErrorMessage
    }

    /// Exact byte identity of a completed download, or nil when it cannot be
    /// trusted: no persisted hash, missing file, or on-disk size drifting
    /// from the recorded byte count (replacement/corruption). The record's
    /// duration is RSS display metadata, not a measurement of the local file.
    func completedSourceIdentity(for episodeID: String) -> OpenCastRemoteTranscriptionSourceIdentity? {
        guard let record = record(for: episodeID),
              record.state == .completed,
              record.sourceFileSHA256.isEmpty == false,
              let fileURL = localFileURL(for: record),
              let fileSize = try? fileStore.fileSize(at: fileURL),
              fileSize == record.bytesReceived
        else {
            return nil
        }
        return OpenCastRemoteTranscriptionSourceIdentity(
            sha256: record.sourceFileSHA256,
            byteCount: record.bytesReceived,
            durationSeconds: nil,
            entityTag: record.entityTag,
            lastModified: record.lastModifiedHeader
        )
    }

    func localFileURL(for record: EpisodeDownloadRecord) -> URL? {
        guard record.state == .completed,
              let relativePath = record.localRelativePath
        else {
            return nil
        }

        return fileStore.fileURL(relativePath: relativePath)
    }

    func downloadedFileExists(for record: EpisodeDownloadRecord) -> Bool {
        guard let relativePath = record.localRelativePath else {
            return false
        }

        return fileStore.fileExists(relativePath: relativePath)
    }

    func markDownloadedFileMissing(
        _ record: EpisodeDownloadRecord,
        modelContext: ModelContext
    ) throws {
        record.state = .missing
        record.errorMessage = EpisodeDownloadError.missingDownloadedFile.localizedDescription
        record.updatedAt = .now
        try commit(episodeID: record.episodeID, modelContext: modelContext, resort: true)
    }

    func startDownload(for episode: EpisodeListItemSnapshot, modelContext: ModelContext) {
        do {
            if let record = record(for: episode.episodeID),
               record.state == .paused || record.state == .failed {
                applyDisplayMetadata(from: episode, to: record)
                if try resumePreservedPartialIfAvailable(record, modelContext: modelContext) {
                    return
                }
            }

            guard let audioURLString = episode.audioURL,
                  let sourceURL = URL(string: audioURLString)
            else {
                try markSetupFailure(
                    episode: episode,
                    message: EpisodeDownloadError.invalidAudioURL.localizedDescription,
                    modelContext: modelContext
                )
                return
            }

            let record = try startDownload(
                episodeID: episode.episodeID,
                podcastID: episode.podcastID,
                sourceAudioURL: sourceURL.absoluteString,
                modelContext: modelContext
            )
            applyDisplayMetadata(from: episode, to: record)
            try commit(episodeID: episode.episodeID, modelContext: modelContext, resort: true)
            lastErrorMessage = nil
            lastErrorEpisodeID = nil
        } catch {
            recordFailure(error, episodeID: episode.episodeID)
        }
    }

    func pauseDownload(episodeID: String, modelContext: ModelContext) {
        guard record(for: episodeID)?.state == .downloading,
              let task = downloadTasks[episodeID]
        else {
            return
        }

        pauseRequestedEpisodeIDs.insert(episodeID)
        task.cancel()
    }

    func resumeDownload(episodeID: String, modelContext: ModelContext) {
        guard let record = record(for: episodeID), record.state == .paused else {
            return
        }

        guard let sourceURL = URL(string: record.sourceAudioURL) else {
            markResumeFailure(
                record,
                error: EpisodeDownloadError.invalidAudioURL,
                modelContext: modelContext
            )
            return
        }

        var resumableTemporaryURL: URL?
        do {
            let token = UUID().uuidString
            try fileStore.prepareDownloadsDirectory()
            let temporaryURL = try fileStore.movePausedPartialToTemporaryFile(
                episodeID: episodeID,
                token: token
            )
            resumableTemporaryURL = temporaryURL
            let offset = try fileStore.fileSize(at: temporaryURL)
            guard offset > 0 else {
                try? fileStore.removeItemIfPresent(at: temporaryURL)
                throw EpisodeDownloadError.interrupted
            }

            let relativePath = record.localRelativePath
                ?? fileStore.relativePath(episodeID: episodeID, sourceAudioURL: sourceURL)
            pauseRequestedEpisodeIDs.remove(episodeID)
            progressCheckpoints[episodeID] = DownloadProgressCheckpoint(
                bytesReceived: offset,
                bytesExpected: record.bytesExpected,
                publishedAt: .now
            )
            liveByteProgressByEpisodeID[episodeID] = DownloadByteProgress(
                bytesReceived: offset,
                bytesExpected: record.bytesExpected
            )
            record.localRelativePath = relativePath
            record.state = .downloading
            record.bytesReceived = offset
            record.sourceFileSHA256 = ""
            record.errorMessage = nil
            record.updatedAt = .now
            try commit(episodeID: episodeID, modelContext: modelContext, resort: true)

            downloadTaskTokens[episodeID] = token
            downloadTasks[episodeID] = makeDownloadTask(
                episodeID: episodeID,
                token: token,
                sourceURL: sourceURL,
                temporaryURL: temporaryURL,
                relativePath: relativePath,
                resume: EpisodeDownloadResumeContext(
                    offset: offset,
                    entityTag: record.entityTag,
                    lastModified: record.lastModifiedHeader
                ),
                modelContext: modelContext
            )
            lastErrorMessage = nil
            lastErrorEpisodeID = nil
        } catch {
            preservePausedDownloadAfterResumeSetupFailure(
                record,
                temporaryURL: resumableTemporaryURL,
                error: error,
                modelContext: modelContext
            )
        }
    }

    func retryDownload(_ record: EpisodeDownloadRecord, modelContext: ModelContext) {
        do {
            if try resumePreservedPartialIfAvailable(record, modelContext: modelContext) {
                return
            }
            guard let sourceURL = URL(string: record.sourceAudioURL) else {
                throw EpisodeDownloadError.invalidAudioURL
            }
            _ = try startDownload(
                episodeID: record.episodeID,
                podcastID: record.podcastID,
                sourceAudioURL: sourceURL.absoluteString,
                modelContext: modelContext
            )
            lastErrorMessage = nil
            lastErrorEpisodeID = nil
        } catch {
            recordFailure(error, episodeID: record.episodeID)
        }
    }

    private func resumePreservedPartialIfAvailable(
        _ record: EpisodeDownloadRecord,
        modelContext: ModelContext
    ) throws -> Bool {
        guard record.state == .paused || record.state == .failed else {
            return false
        }

        let stableURL = fileStore.pausedPartialFileURL(episodeID: record.episodeID)
        let stableSize = try fileSizeIfPresent(at: stableURL)
        let partialSize: Int64?
        if let stableSize, stableSize > 0 {
            partialSize = stableSize
        } else {
            partialSize = try fileStore.adoptNewestTemporaryPartial(episodeID: record.episodeID)
        }
        guard let partialSize, partialSize > 0 else {
            return false
        }

        record.state = .paused
        record.bytesReceived = partialSize
        if let bytesExpected = record.bytesExpected, bytesExpected < partialSize {
            record.bytesExpected = partialSize
        }
        record.errorMessage = nil
        record.updatedAt = .now
        try commit(episodeID: record.episodeID, modelContext: modelContext, resort: true)
        resumeDownload(episodeID: record.episodeID, modelContext: modelContext)
        return true
    }

    func retryAllFailedDownloads(modelContext: ModelContext) {
        let retryRecords = failedOrMissingRecords
        for record in retryRecords {
            retryDownload(record, modelContext: modelContext)
        }
    }

    func cancelDownload(episodeID: String, modelContext: ModelContext) {
        downloadTasks[episodeID]?.cancel()
        downloadTasks[episodeID] = nil
        downloadTaskTokens[episodeID] = nil
        clearTransientProgress(episodeID: episodeID)
        pauseRequestedEpisodeIDs.remove(episodeID)
        stateChanges.notify()

        var cleanupError: Error?
        do {
            try fileStore.removeTemporaryFiles(episodeID: episodeID)
        } catch {
            cleanupError = error
        }
        do {
            try fileStore.removePausedPartial(episodeID: episodeID)
        } catch {
            cleanupError = cleanupError ?? error
        }

        do {
            if let record = try fetchRecords(modelContext: modelContext).first(where: { $0.episodeID == episodeID }),
               record.state == .downloading || record.state == .paused {
                modelContext.delete(record)
            }
            try commit(episodeID: episodeID, modelContext: modelContext)
        } catch {
            recordFailure(error, episodeID: episodeID)
            return
        }

        if let cleanupError {
            recordFailure(cleanupError, episodeID: episodeID)
        }
    }

    func deleteDownload(_ record: EpisodeDownloadRecord, modelContext: ModelContext) {
        do {
            try deleteDownloadThrowing(record, modelContext: modelContext)
        } catch {
            recordFailure(error, episodeID: record.episodeID)
        }
    }

    func deleteDownloads(
        _ records: [EpisodeDownloadRecord],
        modelContext: ModelContext
    ) {
        guard !records.isEmpty else {
            return
        }

        var firstFailure: (error: any Error, episodeID: String)?
        for record in records {
            do {
                try deleteDownloadRecord(record, modelContext: modelContext)
            } catch {
                if firstFailure == nil {
                    firstFailure = (error, record.episodeID)
                }
            }
        }

        if let firstFailure {
            recordFailure(firstFailure.error, episodeID: firstFailure.episodeID)
        } else {
            lastErrorMessage = nil
            lastErrorEpisodeID = nil
        }
    }

    func deleteDownloadThrowing(
        _ record: EpisodeDownloadRecord,
        modelContext: ModelContext
    ) throws {
        try deleteDownloadRecord(record, modelContext: modelContext)
        lastErrorMessage = nil
        lastErrorEpisodeID = nil
    }

    func deleteAllDownloads(modelContext: ModelContext) {
        do {
            let allRecords = try fetchRecords(modelContext: modelContext)
            for record in allRecords {
                try deleteDownloadRecord(record, savesImmediately: false, modelContext: modelContext)
            }
            try modelContext.save()
            try reload(modelContext: modelContext)
            lastErrorMessage = nil
            lastErrorEpisodeID = nil
            stateChanges.notify()
        } catch {
            recordFailure(error)
        }
    }

    func nukeAllDownloads(modelContext: ModelContext) async throws {
        for task in downloadTasks.values {
            task.cancel()
        }
        downloadTasks.removeAll()
        downloadTaskTokens.removeAll()
        progressCheckpoints.removeAll()
        pauseRequestedEpisodeIDs.removeAll()

        for record in try fetchRecords(modelContext: modelContext) {
            modelContext.delete(record)
        }
        try await Self.removeAllDownloadFiles(fileStore: fileStore)
        try modelContext.save()
        records.removeAll()
        lastErrorMessage = nil
        lastErrorEpisodeID = nil
        stateChanges.notify()
    }

    func deleteDownloads(forPodcastID podcastID: String, modelContext: ModelContext) throws {
        let records = try fetchRecords(forPodcastID: podcastID, modelContext: modelContext)
        for record in records {
            try deleteDownloadRecord(record, savesImmediately: false, modelContext: modelContext)
        }
        if !records.isEmpty {
            try modelContext.save()
        }
        try reload(modelContext: modelContext)
        stateChanges.notify()
    }

    func waitForDownload(episodeID: String) async throws {
        while downloadTasks[episodeID] != nil {
            let sequence = stateChanges.sequence
            try await stateChanges.wait(after: sequence)
        }
    }

    func migrateEpisodeSidecars(
        from oldEpisodeID: String,
        to newEpisodeID: String,
        canonicalPodcastID: String,
        modelContext: ModelContext
    ) throws {
        let migratingRecords = try fetchAllRecords(episodeID: oldEpisodeID, modelContext: modelContext)
        guard !migratingRecords.isEmpty else {
            return
        }

        // A still-running old-ID task would race the re-key and the file
        // moves. Orphan it: with its token cleared, every callback
        // token-mismatches, cleans its temporary file, and exits.
        downloadTasks[oldEpisodeID]?.cancel()
        downloadTasks[oldEpisodeID] = nil
        downloadTaskTokens[oldEpisodeID] = nil
        clearTransientProgress(episodeID: oldEpisodeID)
        pauseRequestedEpisodeIDs.remove(oldEpisodeID)

        let targetRecords = try fetchAllRecords(episodeID: newEpisodeID, modelContext: modelContext)
        if targetRecords.contains(where: isMigrationKeeperTarget) {
            // The successor already owns a valid artifact or a live download.
            // Never overwrite it with the old identity's file: drop the old
            // rows; once the deletion is durable the next launch's unclaimed
            // sweep collects their audio. Record-only, so an interrupted save
            // changes nothing on disk.
            duplicateRepairCount += 1
            removeRecordsForMigration(migratingRecords, modelContext: modelContext)
            return
        }

        // No valid successor artifact: the old identity's files migrate over
        // and any invalid successor rows make way.
        if !targetRecords.isEmpty {
            duplicateRepairCount += 1
            removeRecordsForMigration(targetRecords, modelContext: modelContext)
        }
        let newRelativePath = try fileStore.migrateFiles(
            fromEpisodeID: oldEpisodeID,
            to: newEpisodeID,
            localRelativePath: migratingRecords.compactMap(\.localRelativePath).first
        )
        for record in migratingRecords {
            record.episodeID = newEpisodeID
            record.podcastID = canonicalPodcastID
            if record.localRelativePath != nil {
                record.localRelativePath = newRelativePath
            }
        }
    }

    /// A successor row that must survive a collision migration untouched: a
    /// completed download whose file is present with the recorded size, or a
    /// download that is actively in flight.
    private func isMigrationKeeperTarget(_ record: EpisodeDownloadRecord) -> Bool {
        switch record.state {
        case .downloading, .paused:
            return true
        case .completed:
            guard let relativePath = record.localRelativePath,
                  let fileSize = try? fileStore.fileSize(relativePath: relativePath)
            else {
                return false
            }
            return fileSize > 0 && fileSize == record.bytesReceived
        case .failed, .missing:
            return false
        }
    }

    private func removeRecordsForMigration(
        _ recordsToDelete: [EpisodeDownloadRecord],
        modelContext: ModelContext
    ) {
        for record in recordsToDelete {
            modelContext.delete(record)
        }
        let deletedIdentities = Set(recordsToDelete.map(ObjectIdentifier.init))
        records.removeAll { deletedIdentities.contains(ObjectIdentifier($0)) }
        stateChanges.notify()
    }

    enum CompletedDownloadError: Error, Equatable {
        case fileMissing
        case notCompleted(state: EpisodeDownloadState, errorMessage: String?)
    }

    /// One shared "make this episode's download completed" wait loop for the
    /// ad-free pass, transcription-request, and remote-job coordinators.
    /// `onWaitStarted` runs at the top of every iteration — it injects the
    /// caller's cancellation check (plain `Task.checkCancellation` versus a
    /// request-scoped variant) plus any per-iteration phase update, and its
    /// errors propagate unmapped. A `.completed` record whose file is gone is
    /// flipped to `.missing` before this throws, so the store self-heals
    /// instead of handing a caller a URL with no file behind it.
    func ensureCompletedDownload(
        for episode: EpisodeListItemSnapshot,
        modelContext: ModelContext,
        onWaitStarted: () throws -> Void
    ) async throws -> EpisodeDownloadRecord {
        var didStartDownload = false

        while true {
            try onWaitStarted()

            guard let record = record(for: episode.episodeID) else {
                startDownload(for: episode, modelContext: modelContext)
                didStartDownload = true
                try await waitForDownload(episodeID: episode.episodeID)
                continue
            }

            switch record.state {
            case .completed:
                guard downloadedFileExists(for: record) else {
                    try? markDownloadedFileMissing(record, modelContext: modelContext)
                    throw CompletedDownloadError.fileMissing
                }
                return record
            case .downloading:
                try await waitForDownload(episodeID: episode.episodeID)
            case .paused, .failed, .missing:
                guard !didStartDownload else {
                    throw CompletedDownloadError.notCompleted(
                        state: record.state,
                        errorMessage: record.errorMessage
                    )
                }
                startDownload(for: episode, modelContext: modelContext)
                didStartDownload = true
                try await waitForDownload(episodeID: episode.episodeID)
            }
        }
    }

    private func startDownload(
        episodeID: String,
        podcastID: String,
        sourceAudioURL: String,
        modelContext: ModelContext
    ) throws -> EpisodeDownloadRecord {
        guard let sourceURL = URL(string: sourceAudioURL) else {
            throw EpisodeDownloadError.invalidAudioURL
        }

        downloadTasks[episodeID]?.cancel()
        downloadTasks[episodeID] = nil
        downloadTaskTokens[episodeID] = nil
        pauseRequestedEpisodeIDs.remove(episodeID)
        clearTransientProgress(episodeID: episodeID)
        stateChanges.notify()

        try fileStore.prepareDownloadsDirectory()
        try fileStore.removeTemporaryFiles(episodeID: episodeID)
        try fileStore.removePausedPartial(episodeID: episodeID)

        let token = UUID().uuidString
        let relativePath = fileStore.relativePath(episodeID: episodeID, sourceAudioURL: sourceURL)
        let temporaryURL = fileStore.temporaryFileURL(episodeID: episodeID, token: token)
        try fileStore.removeItemIfPresent(at: temporaryURL)
        let record = try upsertRecord(
            episodeID: episodeID,
            podcastID: podcastID,
            sourceAudioURL: sourceURL.absoluteString,
            localRelativePath: relativePath,
            state: .downloading,
            bytesReceived: 0,
            bytesExpected: nil,
            errorMessage: nil,
            modelContext: modelContext
        )
        record.entityTag = nil
        record.lastModifiedHeader = nil
        try commit(episodeID: episodeID, modelContext: modelContext, resort: true)

        downloadTaskTokens[episodeID] = token
        downloadTasks[episodeID] = makeDownloadTask(
            episodeID: episodeID,
            token: token,
            sourceURL: sourceURL,
            temporaryURL: temporaryURL,
            relativePath: relativePath,
            resume: nil,
            modelContext: modelContext
        )
        return record
    }

    private func makeDownloadTask(
        episodeID: String,
        token: String,
        sourceURL: URL,
        temporaryURL: URL,
        relativePath: String,
        resume: EpisodeDownloadResumeContext?,
        modelContext: ModelContext
    ) -> Task<Void, Never> {
        Task { [weak self] in
            await self?.runDownload(
                episodeID: episodeID,
                token: token,
                sourceURL: sourceURL,
                temporaryURL: temporaryURL,
                relativePath: relativePath,
                resume: resume,
                modelContext: modelContext
            )
        }
    }

    private func markResumeFailure(
        _ record: EpisodeDownloadRecord,
        error: Error,
        modelContext: ModelContext
    ) {
        pauseRequestedEpisodeIDs.remove(record.episodeID)
        downloadTasks[record.episodeID] = nil
        downloadTaskTokens[record.episodeID] = nil
        clearTransientProgress(episodeID: record.episodeID)
        try? fileStore.removeTemporaryFiles(episodeID: record.episodeID)
        try? fileStore.removePausedPartial(episodeID: record.episodeID)
        record.state = .failed
        record.errorMessage = error.localizedDescription
        record.updatedAt = .now
        do {
            try commit(episodeID: record.episodeID, modelContext: modelContext, resort: true)
        } catch {
            recordFailure(error, episodeID: record.episodeID)
        }
        recordFailure(error, episodeID: record.episodeID)
    }

    private func markResumeFailurePreservingPartials(
        _ record: EpisodeDownloadRecord,
        error: Error,
        modelContext: ModelContext
    ) {
        pauseRequestedEpisodeIDs.remove(record.episodeID)
        downloadTasks[record.episodeID] = nil
        downloadTaskTokens[record.episodeID] = nil
        clearTransientProgress(episodeID: record.episodeID)
        record.state = .failed
        record.errorMessage = error.localizedDescription
        record.updatedAt = .now
        do {
            try commit(episodeID: record.episodeID, modelContext: modelContext, resort: true)
        } catch {
            recordFailure(error, episodeID: record.episodeID)
        }
        recordFailure(error, episodeID: record.episodeID)
    }

    private func preservePausedDownloadAfterResumeSetupFailure(
        _ record: EpisodeDownloadRecord,
        temporaryURL: URL?,
        error: Error,
        modelContext: ModelContext
    ) {
        let stableURL = fileStore.pausedPartialFileURL(episodeID: record.episodeID)
        let resumableURL = temporaryURL ?? stableURL
        let fileSize: Int64
        do {
            guard let preservedSize = try fileSizeIfPresent(at: resumableURL),
                  preservedSize > 0
            else {
                markResumeFailure(record, error: error, modelContext: modelContext)
                return
            }
            fileSize = preservedSize
        } catch {
            markResumeFailurePreservingPartials(record, error: error, modelContext: modelContext)
            return
        }

        if resumableURL.standardizedFileURL != stableURL.standardizedFileURL {
            do {
                try fileStore.promoteTemporaryFileToPausedPartial(
                    resumableURL,
                    episodeID: record.episodeID
                )
            } catch {
                markResumeFailurePreservingPartials(record, error: error, modelContext: modelContext)
                return
            }
        }

        downloadTasks[record.episodeID] = nil
        downloadTaskTokens[record.episodeID] = nil
        pauseRequestedEpisodeIDs.remove(record.episodeID)
        clearTransientProgress(episodeID: record.episodeID)
        record.state = .paused
        record.bytesReceived = fileSize
        record.errorMessage = nil
        record.updatedAt = .now
        do {
            try commit(episodeID: record.episodeID, modelContext: modelContext, resort: true)
        } catch {
            recordFailure(error, episodeID: record.episodeID)
            return
        }
        recordFailure(error, episodeID: record.episodeID)
    }

    private func runDownload(
        episodeID: String,
        token: String,
        sourceURL: URL,
        temporaryURL: URL,
        relativePath: String,
        resume: EpisodeDownloadResumeContext?,
        modelContext: ModelContext
    ) async {
        defer {
            withCurrentToken(episodeID, token) {
                downloadTasks[episodeID] = nil
                downloadTaskTokens[episodeID] = nil
                pauseRequestedEpisodeIDs.remove(episodeID)
                stateChanges.notify()
            }
        }

        do {
            try await downloader.download(
                from: sourceURL,
                to: temporaryURL,
                resume: resume,
                onResponseMetadata: { [weak self] metadata in
                    self?.updateResponseMetadata(
                        episodeID: episodeID,
                        token: token,
                        metadata: metadata,
                        modelContext: modelContext
                    )
                },
                progress: { [weak self] bytesReceived, bytesExpected in
                    self?.updateProgress(
                        episodeID: episodeID,
                        token: token,
                        bytesReceived: bytesReceived,
                        bytesExpected: bytesExpected
                    )
                }
            )
            try Task.checkCancellation()
            guard withCurrentToken(episodeID, token, {}) else {
                try? fileStore.removeItemIfPresent(at: temporaryURL)
                return
            }

            try fileStore.moveCompletedDownload(from: temporaryURL, relativePath: relativePath)
            let fileSize = try fileStore.fileSize(relativePath: relativePath)
            // Definitive identity is always the completed assembled file, so
            // pause/resume and appended partials cannot skew the hash.
            let sourceFileSHA256 = try await OpenCastSHA256.hashFileOffCaller(
                at: fileStore.fileURL(relativePath: relativePath)
            )
            try Task.checkCancellation()
            try completeDownload(
                episodeID: episodeID,
                token: token,
                relativePath: relativePath,
                bytesReceived: fileSize,
                sourceFileSHA256: sourceFileSHA256,
                modelContext: modelContext
            )
        } catch is CancellationError {
            handleDownloadCancellation(
                episodeID: episodeID,
                token: token,
                temporaryURL: temporaryURL,
                modelContext: modelContext
            )
        } catch {
            if Task.isCancelled {
                handleDownloadCancellation(
                    episodeID: episodeID,
                    token: token,
                    temporaryURL: temporaryURL,
                    modelContext: modelContext
                )
                return
            }
            if resume != nil,
               preservePartialAfterResumedDownloadFailure(
                   episodeID: episodeID,
                   token: token,
                   temporaryURL: temporaryURL,
                   error: error,
                   modelContext: modelContext
               ) {
                return
            }
            try? fileStore.removeItemIfPresent(at: temporaryURL)
            failDownload(episodeID: episodeID, token: token, error: error, modelContext: modelContext)
        }
    }

    private func preservePartialAfterResumedDownloadFailure(
        episodeID: String,
        token: String,
        temporaryURL: URL,
        error: Error,
        modelContext: ModelContext
    ) -> Bool {
        guard downloadTaskTokens[episodeID] == token,
              let record = record(for: episodeID),
              record.state == .downloading
        else {
            return false
        }

        do {
            guard let temporarySize = try fileSizeIfPresent(at: temporaryURL),
                  temporarySize > 0
            else {
                return false
            }
        } catch {
            markResumeFailurePreservingPartials(record, error: error, modelContext: modelContext)
            return true
        }

        let partialSize: Int64
        do {
            partialSize = try fileStore.promoteTemporaryFileToPausedPartial(
                temporaryURL,
                episodeID: episodeID
            )
        } catch {
            markResumeFailurePreservingPartials(record, error: error, modelContext: modelContext)
            return true
        }

        guard partialSize > 0 else {
            return false
        }

        record.state = .failed
        record.bytesReceived = partialSize
        if let bytesExpected = record.bytesExpected ?? liveByteProgressByEpisodeID[episodeID]?.bytesExpected {
            record.bytesExpected = max(bytesExpected, partialSize)
        }
        record.errorMessage = error.localizedDescription
        record.updatedAt = .now
        clearTransientProgress(episodeID: episodeID)
        pauseRequestedEpisodeIDs.remove(episodeID)

        do {
            try commit(episodeID: episodeID, modelContext: modelContext, resort: true)
        } catch {
            // The stable partial still lets startup reconciliation recover even
            // if persisting the failed transition fails in this process.
            recordFailure(error, episodeID: episodeID)
        }
        recordFailure(error, episodeID: episodeID)
        return true
    }

    private func handleDownloadCancellation(
        episodeID: String,
        token: String,
        temporaryURL: URL,
        modelContext: ModelContext
    ) {
        guard downloadTaskTokens[episodeID] == token else {
            try? fileStore.removeItemIfPresent(at: temporaryURL)
            return
        }

        guard pauseRequestedEpisodeIDs.contains(episodeID) else {
            try? fileStore.removeItemIfPresent(at: temporaryURL)
            failDownload(
                episodeID: episodeID,
                token: token,
                error: EpisodeDownloadError.interrupted,
                modelContext: modelContext
            )
            return
        }

        // The record no longer carries live byte totals mid-download, so the
        // durable transitions read the server-reported total from the
        // transient progress (before clearing it).
        let knownBytesExpected = liveByteProgressByEpisodeID[episodeID]?.bytesExpected
        do {
            if let record = try fetchRecord(episodeID: episodeID, modelContext: modelContext),
               record.state == .downloading,
               let bytesExpected = record.bytesExpected ?? knownBytesExpected,
               bytesExpected > 0 {
                let temporaryFileSize = try fileStore.fileSize(at: temporaryURL)
                if temporaryFileSize == bytesExpected,
                   let relativePath = record.localRelativePath {
                    try fileStore.moveCompletedDownload(from: temporaryURL, relativePath: relativePath)
                    try completeDownload(
                        episodeID: episodeID,
                        token: token,
                        relativePath: relativePath,
                        bytesReceived: temporaryFileSize,
                        modelContext: modelContext
                    )
                    return
                }
            }

            let fileSize = try fileStore.promoteTemporaryFileToPausedPartial(
                temporaryURL,
                episodeID: episodeID
            )
            guard fileSize > 0,
                  let record = try fetchRecord(episodeID: episodeID, modelContext: modelContext),
                  record.state == .downloading
            else {
                try fileStore.removePausedPartial(episodeID: episodeID)
                throw EpisodeDownloadError.interrupted
            }

            record.state = .paused
            record.bytesReceived = fileSize
            if let bytesExpected = record.bytesExpected ?? knownBytesExpected {
                record.bytesExpected = max(bytesExpected, fileSize)
            }
            record.errorMessage = nil
            record.updatedAt = .now
            clearTransientProgress(episodeID: episodeID)
            pauseRequestedEpisodeIDs.remove(episodeID)
            try commit(episodeID: episodeID, modelContext: modelContext, resort: true)
            lastErrorMessage = nil
            lastErrorEpisodeID = nil
        } catch {
            try? fileStore.removeItemIfPresent(at: temporaryURL)
            try? fileStore.removePausedPartial(episodeID: episodeID)
            failDownload(episodeID: episodeID, token: token, error: error, modelContext: modelContext)
        }
    }

    private func updateResponseMetadata(
        episodeID: String,
        token: String,
        metadata: EpisodeDownloadResponseMetadata,
        modelContext: ModelContext
    ) {
        do {
            try withCurrentToken(episodeID, token) {
                guard let record = try fetchRecord(episodeID: episodeID, modelContext: modelContext),
                      record.state == .downloading,
                      record.entityTag != metadata.entityTag
                        || record.lastModifiedHeader != metadata.lastModified
                else {
                    return
                }

                record.entityTag = metadata.entityTag
                record.lastModifiedHeader = metadata.lastModified
                record.updatedAt = .now
                try commit(episodeID: episodeID, modelContext: modelContext)
            }
        } catch {
            recordFailure(error, episodeID: episodeID)
        }
    }

    private func updateProgress(
        episodeID: String,
        token: String,
        bytesReceived: Int64,
        bytesExpected: Int64?
    ) {
        withCurrentToken(episodeID, token) {
            guard let record = record(for: episodeID),
                  record.state == .downloading
            else {
                return
            }

            let received = max(0, bytesReceived)
            // The live value must always carry the latest report: the
            // URLSession delegate already coalesces callback frequency, and
            // a report suppressed here would stay lost if it turns out to be
            // the last one before a stall (the resume seed stamps a fresh
            // checkpoint, so the first post-resume report otherwise falls
            // inside the throttle window). Only checkpoint persistence is
            // paced by shouldPublishProgress.
            liveByteProgressByEpisodeID[episodeID] = DownloadByteProgress(
                bytesReceived: received,
                bytesExpected: bytesExpected
            )
            guard shouldPublishProgress(
                episodeID: episodeID,
                bytesReceived: received,
                bytesExpected: bytesExpected
            ) else {
                return
            }

            progressCheckpoints[episodeID] = DownloadProgressCheckpoint(
                bytesReceived: received,
                bytesExpected: bytesExpected,
                publishedAt: .now
            )
        }
    }

    private func completeDownload(
        episodeID: String,
        token: String,
        relativePath: String,
        bytesReceived: Int64,
        sourceFileSHA256: String = "",
        modelContext: ModelContext
    ) throws {
        try withCurrentToken(episodeID, token) {
            guard let record = try fetchRecord(episodeID: episodeID, modelContext: modelContext) else {
                return
            }

            record.state = .completed
            record.localRelativePath = relativePath
            record.sourceFileSHA256 = sourceFileSHA256
            record.bytesReceived = max(0, bytesReceived)
            record.bytesExpected = record.bytesExpected ?? record.bytesReceived
            record.errorMessage = nil
            record.updatedAt = .now
            clearTransientProgress(episodeID: episodeID)
            try commit(episodeID: episodeID, modelContext: modelContext, resort: true)
            lastErrorMessage = nil
            lastErrorEpisodeID = nil
        }
    }

    private func failDownload(
        episodeID: String,
        token: String,
        error: Error,
        modelContext: ModelContext
    ) {
        do {
            try withCurrentToken(episodeID, token) {
                guard let record = try fetchRecord(episodeID: episodeID, modelContext: modelContext) else {
                    return
                }

                record.state = .failed
                record.sourceFileSHA256 = ""
                if let live = liveByteProgressByEpisodeID[episodeID] {
                    record.bytesReceived = max(live.bytesReceived, record.bytesReceived)
                    record.bytesExpected = record.bytesExpected ?? live.bytesExpected
                }
                record.errorMessage = error.localizedDescription
                record.updatedAt = .now
                clearTransientProgress(episodeID: episodeID)
                pauseRequestedEpisodeIDs.remove(episodeID)
                try commit(episodeID: episodeID, modelContext: modelContext, resort: true)
                recordFailure(error, episodeID: episodeID)
            }
        } catch {
            recordFailure(error)
        }
    }

    private func markSetupFailure(
        episode: EpisodeListItemSnapshot,
        message: String,
        modelContext: ModelContext
    ) throws {
        downloadTasks[episode.episodeID]?.cancel()
        downloadTasks[episode.episodeID] = nil
        downloadTaskTokens[episode.episodeID] = nil
        pauseRequestedEpisodeIDs.remove(episode.episodeID)
        clearTransientProgress(episodeID: episode.episodeID)
        try fileStore.removeTemporaryFiles(episodeID: episode.episodeID)
        try fileStore.removePausedPartial(episodeID: episode.episodeID)
        let record = try upsertRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sourceAudioURL: episode.audioURL ?? "",
            localRelativePath: nil,
            state: .failed,
            bytesReceived: 0,
            bytesExpected: nil,
            errorMessage: message,
            modelContext: modelContext
        )
        applyDisplayMetadata(from: episode, to: record)
        try commit(episodeID: episode.episodeID, modelContext: modelContext, resort: true)
        lastErrorMessage = message
        lastErrorEpisodeID = episode.episodeID
    }

    private func applyDisplayMetadata(
        from episode: EpisodeListItemSnapshot,
        to record: EpisodeDownloadRecord
    ) {
        record.episodeTitle = episode.title
        record.podcastTitle = episode.podcastTitle
        record.artworkURLString = episode.artworkURL
        record.duration = episode.duration
        record.publishedAt = episode.publishedAt
    }

    private func deleteDownloadRecord(
        _ record: EpisodeDownloadRecord,
        savesImmediately: Bool = true,
        modelContext: ModelContext
    ) throws {
        downloadTasks[record.episodeID]?.cancel()
        downloadTasks[record.episodeID] = nil
        downloadTaskTokens[record.episodeID] = nil
        clearTransientProgress(episodeID: record.episodeID)
        pauseRequestedEpisodeIDs.remove(record.episodeID)
        stateChanges.notify()

        try fileStore.removeTemporaryFiles(episodeID: record.episodeID)
        try fileStore.removePausedPartial(episodeID: record.episodeID)
        try fileStore.removeFile(relativePath: record.localRelativePath)
        modelContext.delete(record)

        if savesImmediately {
            try commit(episodeID: record.episodeID, modelContext: modelContext)
        }
    }

    // The per-record file probes and partial adoption run off the main actor
    // (@concurrent worker); record mutations commit back here, each guarded
    // on the state the file system was actually probed for, so actor
    // reentrancy across the hop can never apply a stale verdict. The
    // adoption/repair semantics mirror the pre-hop loop case for case.
    private func reconcile(modelContext: ModelContext) async throws {
        var fetchedRecords = try fetchRecords(modelContext: modelContext)
        var changed = false

        let repairedGroupCount = repairDuplicateRecordGroups(&fetchedRecords, modelContext: modelContext)
        if repairedGroupCount > 0 {
            duplicateRepairCount += repairedGroupCount
            changed = true
        }

        let inputs = fetchedRecords.map { record in
            ReconcileFileInput(
                episodeID: record.episodeID,
                state: record.state,
                localRelativePath: record.localRelativePath
            )
        }
        let claimedRelativePaths = fetchedRecords.compactMap(\.localRelativePath)
        let claimedEpisodeIDs = fetchedRecords.map(\.episodeID)
        let outcomes = try await Self.reconcileFileOutcomes(inputs: inputs, fileStore: fileStore)

        for record in fetchedRecords {
            guard let outcome = outcomes[record.episodeID] else {
                continue
            }
            switch outcome {
            case .finalizeCompleted(let size):
                guard record.state == .downloading else { continue }
                // Completion moves the file before saving the terminal
                // record state. Recover a process death in that small gap.
                record.state = .completed
                record.bytesReceived = size
                record.bytesExpected = size
                record.errorMessage = nil
                record.updatedAt = .now
                changed = true
            case .pauseWithBytes(let resumableByteCount):
                guard record.state == .downloading else { continue }
                record.state = .paused
                record.bytesReceived = resumableByteCount
                if let bytesExpected = record.bytesExpected, bytesExpected < resumableByteCount {
                    record.bytesExpected = resumableByteCount
                }
                record.errorMessage = nil
                record.updatedAt = .now
                changed = true
            case .failInterrupted:
                guard record.state == .downloading else { continue }
                record.state = .failed
                record.errorMessage = EpisodeDownloadError.interrupted.localizedDescription
                record.updatedAt = .now
                changed = true
            case .refreshPausedBytes(let partialSize):
                guard record.state == .paused else { continue }
                var pausedRecordChanged = false
                if record.bytesReceived != partialSize {
                    record.bytesReceived = partialSize
                    pausedRecordChanged = true
                }
                if let bytesExpected = record.bytesExpected, bytesExpected < partialSize {
                    record.bytesExpected = partialSize
                    pausedRecordChanged = true
                }
                if record.errorMessage != nil {
                    record.errorMessage = nil
                    pausedRecordChanged = true
                }
                if pausedRecordChanged {
                    record.updatedAt = .now
                    changed = true
                }
            case .failPausedInterrupted:
                guard record.state == .paused else { continue }
                record.state = .failed
                record.bytesReceived = 0
                record.errorMessage = EpisodeDownloadError.interrupted.localizedDescription
                record.updatedAt = .now
                changed = true
            case .markMissing:
                guard record.state == .completed else { continue }
                record.state = .missing
                record.errorMessage = EpisodeDownloadError.missingDownloadedFile.localizedDescription
                record.updatedAt = .now
                changed = true
            case .refreshCompletedSize(let fileSize):
                guard record.state == .completed else { continue }
                if record.bytesReceived != fileSize {
                    record.bytesReceived = fileSize
                    record.updatedAt = .now
                    changed = true
                }
            }
        }

        if changed {
            try modelContext.save()
        }

        try await Self.removeUnclaimedFiles(
            claimedRelativePaths: claimedRelativePaths,
            claimedEpisodeIDs: claimedEpisodeIDs,
            fileStore: fileStore
        )
    }

    private struct ReconcileFileInput: Sendable {
        let episodeID: String
        let state: EpisodeDownloadState
        let localRelativePath: String?
    }

    private enum ReconcileFileOutcome: Sendable {
        case finalizeCompleted(size: Int64)
        case pauseWithBytes(Int64)
        case failInterrupted
        case refreshPausedBytes(Int64)
        case failPausedInterrupted
        case markMissing
        case refreshCompletedSize(Int64)
    }

    @concurrent
    private static func reconcileFileOutcomes(
        inputs: [ReconcileFileInput],
        fileStore: EpisodeDownloadFileStore
    ) async throws -> [String: ReconcileFileOutcome] {
        var outcomes: [String: ReconcileFileOutcome] = [:]
        for input in inputs {
            switch input.state {
            case .downloading:
                if let relativePath = input.localRelativePath,
                   fileStore.fileExists(relativePath: relativePath) {
                    let completedSize = try fileStore.fileSize(relativePath: relativePath)
                    if completedSize > 0 {
                        outcomes[input.episodeID] = .finalizeCompleted(size: completedSize)
                        continue
                    }
                }
                let adoptedByteCount = try fileStore.adoptNewestTemporaryPartial(episodeID: input.episodeID)
                let resumableByteCount = try adoptedByteCount ?? fileSizeIfPresent(
                    at: fileStore.pausedPartialFileURL(episodeID: input.episodeID),
                    fileStore: fileStore
                )
                if let resumableByteCount, resumableByteCount > 0 {
                    outcomes[input.episodeID] = .pauseWithBytes(resumableByteCount)
                } else {
                    try fileStore.removePausedPartial(episodeID: input.episodeID)
                    outcomes[input.episodeID] = .failInterrupted
                }
            case .paused:
                let partialURL = fileStore.pausedPartialFileURL(episodeID: input.episodeID)
                let stablePartialSize = try fileSizeIfPresent(at: partialURL, fileStore: fileStore)
                let partialSize: Int64?
                if let stablePartialSize, stablePartialSize > 0 {
                    partialSize = stablePartialSize
                } else {
                    // Resume moves the stable partial to a token file before
                    // persisting `.downloading`. Recover that narrow crash
                    // window without throwing away otherwise resumable bytes.
                    partialSize = try fileStore.adoptNewestTemporaryPartial(
                        episodeID: input.episodeID
                    )
                }
                if let partialSize, partialSize > 0 {
                    outcomes[input.episodeID] = .refreshPausedBytes(partialSize)
                } else {
                    try fileStore.removePausedPartial(episodeID: input.episodeID)
                    outcomes[input.episodeID] = .failPausedInterrupted
                }
            case .completed:
                guard let relativePath = input.localRelativePath,
                      fileStore.fileExists(relativePath: relativePath)
                else {
                    outcomes[input.episodeID] = .markMissing
                    continue
                }
                outcomes[input.episodeID] = .refreshCompletedSize(
                    try fileStore.fileSize(relativePath: relativePath)
                )
            case .failed, .missing:
                break
            }
        }
        return outcomes
    }

    @concurrent
    private static func removeUnclaimedFiles(
        claimedRelativePaths: [String],
        claimedEpisodeIDs: [String],
        fileStore: EpisodeDownloadFileStore
    ) async throws {
        try fileStore.removeUnclaimedFiles(
            claimedRelativePaths: claimedRelativePaths,
            claimedEpisodeIDs: claimedEpisodeIDs
        )
    }

    @concurrent
    private static func removeAllDownloadFiles(
        fileStore: EpisodeDownloadFileStore
    ) async throws {
        try fileStore.removeAllDownloads()
    }

    private func fileSizeIfPresent(at url: URL) throws -> Int64? {
        try Self.fileSizeIfPresent(at: url, fileStore: fileStore)
    }

    nonisolated private static func fileSizeIfPresent(
        at url: URL,
        fileStore: EpisodeDownloadFileStore
    ) throws -> Int64? {
        do {
            return try fileStore.fileSize(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile
            || error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// Collapses duplicate records left under one episode ID by an identity
    /// migration collision. The survivor is the record the physical file
    /// proves — an exact stored-hash match outranks a byte-count match — and
    /// a group no row can prove keeps one deterministic record marked
    /// `.missing` so nothing claims a false identity. Record-only: loser
    /// files become unclaimed once the save is durable, and the sweep at the
    /// end of `reconcile` collects them.
    private func repairDuplicateRecordGroups(
        _ fetchedRecords: inout [EpisodeDownloadRecord],
        modelContext: ModelContext
    ) -> Int {
        var groupsByEpisodeID: [String: [EpisodeDownloadRecord]] = [:]
        for record in fetchedRecords {
            groupsByEpisodeID[record.episodeID, default: []].append(record)
        }
        let duplicateGroups = groupsByEpisodeID.values.filter { $0.count > 1 }
        guard !duplicateGroups.isEmpty else {
            return 0
        }

        let subscribedFeedURLs = EpisodeSidecarRepair.subscribedFeedURLs(modelContext: modelContext)
        var fileHashCache: [String: String?] = [:]
        func provenFileHash(relativePath: String) -> String? {
            if let cached = fileHashCache[relativePath] {
                return cached
            }
            let hash = try? OpenCastSHA256.hashFile(at: fileStore.fileURL(relativePath: relativePath))
            fileHashCache[relativePath] = hash
            return hash
        }

        var removedIdentities = Set<ObjectIdentifier>()
        for group in duplicateGroups {
            let ordered = group
                .map { record in
                    (record: record, verdict: assessForRepair(record, provenFileHash: provenFileHash))
                }
                .sorted { lhs, rhs in
                    if lhs.verdict.score != rhs.verdict.score {
                        return lhs.verdict.score > rhs.verdict.score
                    }
                    if lhs.record.updatedAt != rhs.record.updatedAt {
                        return lhs.record.updatedAt > rhs.record.updatedAt
                    }
                    if lhs.record.createdAt != rhs.record.createdAt {
                        return lhs.record.createdAt > rhs.record.createdAt
                    }
                    return EpisodeSidecarRepair.stableOrderingKey(lhs.record)
                        < EpisodeSidecarRepair.stableOrderingKey(rhs.record)
                }
            guard let winner = ordered.first else {
                continue
            }

            applyRepairOutcome(winner.verdict, to: winner.record)
            if let podcastID = EpisodeSidecarRepair.preferredPodcastID(
                orderedCandidates: ordered.map(\.record.podcastID),
                subscribedFeedURLs: subscribedFeedURLs
            ), winner.record.podcastID != podcastID {
                winner.record.podcastID = podcastID
                winner.record.updatedAt = .now
            }
            for loser in ordered.dropFirst() {
                modelContext.delete(loser.record)
                removedIdentities.insert(ObjectIdentifier(loser.record))
            }
        }

        fetchedRecords.removeAll { removedIdentities.contains(ObjectIdentifier($0)) }
        return duplicateGroups.count
    }

    private enum DownloadRepairVerdict {
        case provenByHash(fileSize: Int64)
        /// Rows persisted before completed-file hashing existed can only be
        /// proven by byte count.
        case consistentUnhashed(fileSize: Int64)
        /// Completed, but the file on disk contradicts the record.
        case unproven
        /// Downloading/paused; the per-state reconciliation pass owns these.
        case resumable
        case dead

        var score: Int {
            switch self {
            case .provenByHash: 4
            case .consistentUnhashed: 3
            case .unproven: 2
            case .resumable: 1
            case .dead: 0
            }
        }
    }

    private func assessForRepair(
        _ record: EpisodeDownloadRecord,
        provenFileHash: (String) -> String?
    ) -> DownloadRepairVerdict {
        switch record.state {
        case .completed:
            guard let relativePath = record.localRelativePath,
                  let fileSize = try? fileStore.fileSize(relativePath: relativePath)
            else {
                return .dead
            }
            if !record.sourceFileSHA256.isEmpty {
                return provenFileHash(relativePath) == record.sourceFileSHA256
                    ? .provenByHash(fileSize: fileSize)
                    : .unproven
            }
            return fileSize == record.bytesReceived
                ? .consistentUnhashed(fileSize: fileSize)
                : .unproven
        case .downloading, .paused:
            return .resumable
        case .failed, .missing:
            return .dead
        }
    }

    private func applyRepairOutcome(_ verdict: DownloadRepairVerdict, to record: EpisodeDownloadRecord) {
        switch verdict {
        case .provenByHash(let fileSize), .consistentUnhashed(let fileSize):
            if record.bytesReceived != fileSize {
                record.bytesReceived = fileSize
                record.updatedAt = .now
            }
        case .unproven:
            // The file exists but matches no surviving identity; an explicit
            // re-download replaces it rather than any record claiming it
            // falsely. The path stays so the sweep keeps the file claimed
            // until then.
            record.state = .missing
            record.sourceFileSHA256 = ""
            record.errorMessage = EpisodeDownloadError.invalidDownloadedRecord.localizedDescription
            record.updatedAt = .now
        case .resumable, .dead:
            break
        }
    }

    private func upsertRecord(
        episodeID: String,
        podcastID: String,
        sourceAudioURL: String,
        localRelativePath: String?,
        state: EpisodeDownloadState,
        bytesReceived: Int64,
        bytesExpected: Int64?,
        errorMessage: String?,
        modelContext: ModelContext
    ) throws -> EpisodeDownloadRecord {
        let matchingRecords = try fetchRecords(modelContext: modelContext)
            .filter { $0.episodeID == episodeID }
        let record: EpisodeDownloadRecord
        if let existingRecord = matchingRecords.first {
            record = existingRecord
        } else {
            record = EpisodeDownloadRecord(
                episodeID: episodeID,
                podcastID: podcastID,
                sourceAudioURL: sourceAudioURL
            )
            modelContext.insert(record)
        }

        for duplicateRecord in matchingRecords.dropFirst() {
            modelContext.delete(duplicateRecord)
        }

        record.podcastID = podcastID
        record.sourceAudioURL = sourceAudioURL
        record.localRelativePath = localRelativePath
        record.state = state
        record.bytesReceived = bytesReceived
        record.bytesExpected = bytesExpected
        record.errorMessage = errorMessage
        record.updatedAt = .now
        return record
    }

    private func commit(
        episodeID: String,
        modelContext: ModelContext,
        resort: Bool = false
    ) throws {
        try modelContext.save()
        if let record = try fetchStoredRecord(episodeID: episodeID, modelContext: modelContext) {
            updateLoadedRecord(record, resort: resort)
        } else {
            removeLoadedRecord(episodeID: episodeID)
        }
    }

    @discardableResult
    private func withCurrentToken(
        _ episodeID: String,
        _ token: String,
        _ work: () throws -> Void
    ) rethrows -> Bool {
        guard downloadTaskTokens[episodeID] == token else {
            return false
        }

        try work()
        return true
    }

    private func clearTransientProgress(episodeID: String) {
        progressCheckpoints[episodeID] = nil
        liveByteProgressByEpisodeID[episodeID] = nil
    }

    private func shouldPublishProgress(
        episodeID: String,
        bytesReceived: Int64,
        bytesExpected: Int64?
    ) -> Bool {
        guard let checkpoint = progressCheckpoints[episodeID] else {
            return true
        }

        guard checkpoint.bytesReceived != bytesReceived || checkpoint.bytesExpected != bytesExpected else {
            return false
        }

        if bytesExpected.map({ bytesReceived >= $0 }) == true {
            return true
        }

        return Date.now.timeIntervalSince(checkpoint.publishedAt)
            >= Self.minimumProgressPublicationInterval
    }

    private func updateLoadedRecord(_ record: EpisodeDownloadRecord, resort: Bool = false) {
        if let index = records.firstIndex(where: { $0.episodeID == record.episodeID }) {
            records[index] = record
        } else {
            records.append(record)
        }

        if resort {
            records.sort { $0.updatedAt > $1.updatedAt }
        }
        stateChanges.notify()
    }

    private func removeLoadedRecord(episodeID: String) {
        records.removeAll { $0.episodeID == episodeID }
        stateChanges.notify()
    }

    private func reload(modelContext: ModelContext) throws {
        records = try fetchRecords(modelContext: modelContext)
    }

    private func fetchRecord(
        episodeID: String,
        modelContext: ModelContext
    ) throws -> EpisodeDownloadRecord? {
        if let record = record(for: episodeID) {
            return record
        }

        return try fetchStoredRecord(episodeID: episodeID, modelContext: modelContext)
    }

    private func fetchStoredRecord(
        episodeID: String,
        modelContext: ModelContext
    ) throws -> EpisodeDownloadRecord? {
        let targetEpisodeID = episodeID
        var descriptor = FetchDescriptor<EpisodeDownloadRecord>(
            predicate: #Predicate { record in
                record.episodeID == targetEpisodeID
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchRecords(modelContext: ModelContext) throws -> [EpisodeDownloadRecord] {
        try modelContext.fetch(
            FetchDescriptor<EpisodeDownloadRecord>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        )
    }

    private func fetchAllRecords(
        episodeID: String,
        modelContext: ModelContext
    ) throws -> [EpisodeDownloadRecord] {
        let targetEpisodeID = episodeID
        return try modelContext.fetch(
            FetchDescriptor<EpisodeDownloadRecord>(
                predicate: #Predicate { record in
                    record.episodeID == targetEpisodeID
                },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        )
    }

    private func fetchRecords(
        forPodcastID podcastID: String,
        modelContext: ModelContext
    ) throws -> [EpisodeDownloadRecord] {
        let targetPodcastID = podcastID
        return try modelContext.fetch(
            FetchDescriptor<EpisodeDownloadRecord>(
                predicate: #Predicate { record in
                    record.podcastID == targetPodcastID
                },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        )
    }

    private func storedAutoDeletePreference(modelContext: ModelContext) throws -> Bool {
        guard let value = try LocalPreferenceRecord.preference(
            forKey: Self.autoDeletePlayedEpisodesPreferenceKey,
            modelContext: modelContext
        )?.value else {
            return false
        }

        return Bool(value) ?? false
    }

    private func recordFailure(_ error: Error, episodeID: String? = nil) {
        lastErrorMessage = error.localizedDescription
        lastErrorEpisodeID = episodeID
        stateChanges.notify()
    }

    private struct DownloadProgressCheckpoint {
        let bytesReceived: Int64
        let bytesExpected: Int64?
        let publishedAt: Date

        init(bytesReceived: Int64, bytesExpected: Int64?, publishedAt: Date) {
            self.bytesReceived = bytesReceived
            self.bytesExpected = bytesExpected
            self.publishedAt = publishedAt
        }
    }
}

struct DownloadByteProgress: Equatable {
    var bytesReceived: Int64
    var bytesExpected: Int64?

    var fractionCompleted: Double? {
        guard let bytesExpected, bytesExpected > 0 else {
            return nil
        }
        return min(max(Double(bytesReceived) / Double(bytesExpected), 0), 1)
    }
}
