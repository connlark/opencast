import Foundation
import Observation
import OpenCastCore
import SwiftData

@Observable
final class DownloadStore {
    private(set) var records: [EpisodeDownloadRecord] = []
    private(set) var lastErrorMessage: String?
    private var lastErrorEpisodeID: String?

    @ObservationIgnored private let downloader: any EpisodeAudioDownloading
    @ObservationIgnored private let fileStore: EpisodeDownloadFileStore
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var downloadTaskTokens: [String: String] = [:]
    @ObservationIgnored private var progressCheckpoints: [String: DownloadProgressCheckpoint] = [:]

    private static let minimumProgressSaveInterval: TimeInterval = 0.25
    private static let minimumProgressFractionDelta = 0.01

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

    func load(modelContext: ModelContext) {
        do {
            try reconcile(modelContext: modelContext)
            try reload(modelContext: modelContext)
            lastErrorMessage = nil
            lastErrorEpisodeID = nil
        } catch {
            recordFailure(error)
        }
    }

    func record(for episodeID: String) -> EpisodeDownloadRecord? {
        records.first { $0.episodeID == episodeID }
    }

    func lastErrorMessage(for episodeID: String) -> String? {
        guard lastErrorEpisodeID == episodeID else {
            return nil
        }

        return lastErrorMessage
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

            cancelDownload(episodeID: episode.episodeID, modelContext: modelContext)
            progressCheckpoints[episode.episodeID] = nil

            let token = UUID().uuidString
            let relativePath = fileStore.relativePath(episodeID: episode.episodeID, sourceAudioURL: sourceURL)
            let temporaryURL = fileStore.temporaryFileURL(episodeID: episode.episodeID, token: token)
            try fileStore.prepareDownloadsDirectory()
            try fileStore.removeItemIfPresent(at: temporaryURL)

            _ = try upsertRecord(
                episodeID: episode.episodeID,
                podcastID: episode.podcastID,
                sourceAudioURL: sourceURL.absoluteString,
                localRelativePath: relativePath,
                state: .downloading,
                bytesReceived: 0,
                bytesExpected: nil,
                errorMessage: nil,
                modelContext: modelContext
            )
            try commit(episodeID: episode.episodeID, modelContext: modelContext, resort: true)

            downloadTaskTokens[episode.episodeID] = token
            downloadTasks[episode.episodeID] = Task { [weak self] in
                await self?.runDownload(
                    episodeID: episode.episodeID,
                    token: token,
                    sourceURL: sourceURL,
                    temporaryURL: temporaryURL,
                    relativePath: relativePath,
                    modelContext: modelContext
                )
            }
            lastErrorMessage = nil
            lastErrorEpisodeID = nil
        } catch {
            recordFailure(error)
        }
    }

    func cancelDownload(episodeID: String, modelContext: ModelContext) {
        downloadTasks[episodeID]?.cancel()
        downloadTasks[episodeID] = nil
        downloadTaskTokens[episodeID] = nil
        progressCheckpoints[episodeID] = nil

        do {
            try fileStore.removeTemporaryFiles(episodeID: episodeID)
            if let record = try fetchRecords(modelContext: modelContext).first(where: { $0.episodeID == episodeID }),
               record.state == .downloading {
                modelContext.delete(record)
            }
            try commit(episodeID: episodeID, modelContext: modelContext)
        } catch {
            recordFailure(error)
        }
    }

    func deleteDownload(_ record: EpisodeDownloadRecord, modelContext: ModelContext) {
        do {
            try deleteDownloadRecord(record, modelContext: modelContext)
            lastErrorMessage = nil
            lastErrorEpisodeID = nil
        } catch {
            recordFailure(error)
        }
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
        } catch {
            recordFailure(error)
        }
    }

    func nukeAllDownloads(modelContext: ModelContext) throws {
        for task in downloadTasks.values {
            task.cancel()
        }
        downloadTasks.removeAll()
        downloadTaskTokens.removeAll()
        progressCheckpoints.removeAll()

        for record in try fetchRecords(modelContext: modelContext) {
            modelContext.delete(record)
        }
        try fileStore.removeAllDownloads()
        try modelContext.save()
        records.removeAll()
        lastErrorMessage = nil
        lastErrorEpisodeID = nil
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
    }

    func waitForDownload(episodeID: String) async {
        await downloadTasks[episodeID]?.value
    }

    private func runDownload(
        episodeID: String,
        token: String,
        sourceURL: URL,
        temporaryURL: URL,
        relativePath: String,
        modelContext: ModelContext
    ) async {
        defer {
            withCurrentToken(episodeID, token) {
                downloadTasks[episodeID] = nil
                downloadTaskTokens[episodeID] = nil
            }
        }

        do {
            try await downloader.download(from: sourceURL, to: temporaryURL) { [weak self] bytesReceived, bytesExpected in
                self?.updateProgress(
                    episodeID: episodeID,
                    token: token,
                    bytesReceived: bytesReceived,
                    bytesExpected: bytesExpected,
                    modelContext: modelContext
                )
            }
            try Task.checkCancellation()
            guard withCurrentToken(episodeID, token, {}) else {
                try? fileStore.removeItemIfPresent(at: temporaryURL)
                return
            }

            try fileStore.moveCompletedDownload(from: temporaryURL, relativePath: relativePath)
            let fileSize = try fileStore.fileSize(relativePath: relativePath)
            try completeDownload(
                episodeID: episodeID,
                token: token,
                relativePath: relativePath,
                bytesReceived: fileSize,
                modelContext: modelContext
            )
        } catch is CancellationError {
            try? fileStore.removeItemIfPresent(at: temporaryURL)
        } catch {
            try? fileStore.removeItemIfPresent(at: temporaryURL)
            failDownload(episodeID: episodeID, token: token, error: error, modelContext: modelContext)
        }
    }

    private func updateProgress(
        episodeID: String,
        token: String,
        bytesReceived: Int64,
        bytesExpected: Int64?,
        modelContext: ModelContext
    ) {
        do {
            try withCurrentToken(episodeID, token) {
                guard let record = try fetchRecord(episodeID: episodeID, modelContext: modelContext),
                      record.state == .downloading
                else {
                    return
                }

                let received = max(0, bytesReceived)
                guard record.bytesReceived != received || record.bytesExpected != bytesExpected else {
                    return
                }
                guard shouldPersistProgress(
                    episodeID: episodeID,
                    bytesReceived: received,
                    bytesExpected: bytesExpected
                ) else {
                    return
                }

                record.bytesReceived = received
                record.bytesExpected = bytesExpected
                record.updatedAt = .now
                try commit(episodeID: episodeID, modelContext: modelContext)
                progressCheckpoints[episodeID] = DownloadProgressCheckpoint(
                    bytesReceived: received,
                    bytesExpected: bytesExpected,
                    savedAt: record.updatedAt
                )
            }
        } catch {
            recordFailure(error)
        }
    }

    private func completeDownload(
        episodeID: String,
        token: String,
        relativePath: String,
        bytesReceived: Int64,
        modelContext: ModelContext
    ) throws {
        try withCurrentToken(episodeID, token) {
            guard let record = try fetchRecord(episodeID: episodeID, modelContext: modelContext) else {
                return
            }

            record.state = .completed
            record.localRelativePath = relativePath
            record.bytesReceived = max(0, bytesReceived)
            record.bytesExpected = record.bytesExpected ?? record.bytesReceived
            record.errorMessage = nil
            record.updatedAt = .now
            progressCheckpoints[episodeID] = nil
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
                record.errorMessage = error.localizedDescription
                record.updatedAt = .now
                progressCheckpoints[episodeID] = nil
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
        _ = try upsertRecord(
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
        try commit(episodeID: episode.episodeID, modelContext: modelContext, resort: true)
        lastErrorMessage = message
        lastErrorEpisodeID = episode.episodeID
    }

    private func deleteDownloadRecord(
        _ record: EpisodeDownloadRecord,
        savesImmediately: Bool = true,
        modelContext: ModelContext
    ) throws {
        downloadTasks[record.episodeID]?.cancel()
        downloadTasks[record.episodeID] = nil
        downloadTaskTokens[record.episodeID] = nil
        progressCheckpoints[record.episodeID] = nil

        try fileStore.removeTemporaryFiles(episodeID: record.episodeID)
        try fileStore.removeFile(relativePath: record.localRelativePath)
        modelContext.delete(record)

        if savesImmediately {
            try commit(episodeID: record.episodeID, modelContext: modelContext)
        }
    }

    private func reconcile(modelContext: ModelContext) throws {
        let fetchedRecords = try fetchRecords(modelContext: modelContext)
        var changed = false

        for record in fetchedRecords {
            switch record.state {
            case .downloading:
                try fileStore.removeTemporaryFiles(episodeID: record.episodeID)
                record.state = .failed
                record.errorMessage = EpisodeDownloadError.interrupted.localizedDescription
                record.updatedAt = .now
                changed = true
            case .completed:
                guard let relativePath = record.localRelativePath,
                      fileStore.fileExists(relativePath: relativePath)
                else {
                    record.state = .missing
                    record.errorMessage = EpisodeDownloadError.missingDownloadedFile.localizedDescription
                    record.updatedAt = .now
                    changed = true
                    continue
                }

                let fileSize = try fileStore.fileSize(relativePath: relativePath)
                if record.bytesReceived != fileSize {
                    record.bytesReceived = fileSize
                    record.updatedAt = .now
                    changed = true
                }
            case .failed, .missing:
                break
            }
        }

        if changed {
            try modelContext.save()
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

    private func shouldPersistProgress(
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

        if Date.now.timeIntervalSince(checkpoint.savedAt) >= Self.minimumProgressSaveInterval {
            return true
        }

        guard let fraction = progressFraction(bytesReceived: bytesReceived, bytesExpected: bytesExpected) else {
            return false
        }

        guard let checkpointFraction = checkpoint.progressFraction else {
            return true
        }

        return abs(fraction - checkpointFraction) >= Self.minimumProgressFractionDelta
    }

    private func progressFraction(bytesReceived: Int64, bytesExpected: Int64?) -> Double? {
        guard let bytesExpected, bytesExpected > 0 else {
            return nil
        }

        return Double(bytesReceived) / Double(bytesExpected)
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
    }

    private func removeLoadedRecord(episodeID: String) {
        records.removeAll { $0.episodeID == episodeID }
    }

    private func reload(modelContext: ModelContext) throws {
        records = try fetchRecords(modelContext: modelContext)
    }

    private func fetchRecord(
        episodeID: String,
        modelContext: ModelContext
    ) throws -> EpisodeDownloadRecord? {
        if let record = records.first(where: { $0.episodeID == episodeID }) {
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

    private func recordFailure(_ error: Error, episodeID: String? = nil) {
        lastErrorMessage = error.localizedDescription
        lastErrorEpisodeID = episodeID
    }

    private struct DownloadProgressCheckpoint {
        let bytesReceived: Int64
        let bytesExpected: Int64?
        let progressFraction: Double?
        let savedAt: Date

        init(bytesReceived: Int64, bytesExpected: Int64?, savedAt: Date) {
            self.bytesReceived = bytesReceived
            self.bytesExpected = bytesExpected
            if let bytesExpected, bytesExpected > 0 {
                progressFraction = Double(bytesReceived) / Double(bytesExpected)
            } else {
                progressFraction = nil
            }
            self.savedAt = savedAt
        }
    }
}
