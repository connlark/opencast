import Foundation
import Observation
import SwiftData

/// The data nuke: every store's destructive reset in a fixed order, the
/// SwiftData row wipe, and the local-cache clears. The app model hands in
/// its own two runtime steps — the pre-nuke queue and session teardown, and
/// the post-wipe runtime reset that runs before any later suspension so the
/// UI never renders deleted-and-saved records.
@Observable
final class DataNukeRunner {
    private(set) var isNukingData = false
    private(set) var lastErrorMessage: String?
    private(set) var completionID = 0

    @ObservationIgnored private let syncStatus: SyncStatusStore
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let downloads: DownloadStore
    @ObservationIgnored private let transcriptions: EpisodeTranscriptionStore
    @ObservationIgnored private let adAnalyses: EpisodeAdAnalysisStore
    @ObservationIgnored private let transcriptAnalyses: EpisodeTranscriptAnalysisStore
    @ObservationIgnored private let transcriptionModels: TranscriptionModelStore
    @ObservationIgnored private let cacheController: OpenCastCacheController
    @ObservationIgnored private let siriMediaDiscovery: SiriMediaDiscovery
    /// Runs after the iCloud check and before any store is nuked.
    @ObservationIgnored var prepareRuntime: () async -> Void = {}
    /// Runs after the row wipe and before the cache clears.
    @ObservationIgnored var resetRuntime: (ModelContext) async -> Void = { _ in }

    init(
        syncStatus: SyncStatusStore,
        library: LibraryStore,
        downloads: DownloadStore,
        transcriptions: EpisodeTranscriptionStore,
        adAnalyses: EpisodeAdAnalysisStore,
        transcriptAnalyses: EpisodeTranscriptAnalysisStore,
        transcriptionModels: TranscriptionModelStore,
        cacheController: OpenCastCacheController,
        siriMediaDiscovery: SiriMediaDiscovery
    ) {
        self.syncStatus = syncStatus
        self.library = library
        self.downloads = downloads
        self.transcriptions = transcriptions
        self.adAnalyses = adAnalyses
        self.transcriptAnalyses = transcriptAnalyses
        self.transcriptionModels = transcriptionModels
        self.cacheController = cacheController
        self.siriMediaDiscovery = siriMediaDiscovery
    }

    func run(modelContext: ModelContext) async throws {
        guard !isNukingData else {
            return
        }

        isNukingData = true
        lastErrorMessage = nil
        defer {
            isNukingData = false
        }

        do {
            let accountStatus = await syncStatus.refreshAccountStatus(force: true)
            guard accountStatus == .available else {
                throw DataNukeError.iCloudUnavailable(accountStatus)
            }

            await prepareRuntime()
            try await adAnalyses.nukeAllAnalyses(modelContext: modelContext)
            try await transcriptAnalyses.nukeAllAnalyses(modelContext: modelContext)
            try await transcriptions.nukeAllTranscripts(modelContext: modelContext)
            try await downloads.nukeAllDownloads(modelContext: modelContext)
            try transcriptionModels.deleteInstalledModelImmediately()
            let siriPodcastIDs = library.activePodcastIDs
            try deleteAllModelRows(modelContext: modelContext)
            siriMediaDiscovery.deleteDonations(forPodcastIDs: siriPodcastIDs)
            // Nothing that suspends may sit between the row wipe above and
            // the playback unload at the top of resetRuntime: playback keeps
            // flushing progress through every earlier await, and a flush that
            // landed here would re-insert a row the wipe just deleted.
            // Progress writes carry no write-generation token, so this
            // ordering is their only guard (LibraryStoreNukeRaceProbeTests
            // pins it).
            await resetRuntime(modelContext)
            try await library.deleteAllLocalCache()
            try await cacheController.clearCachesNow()
            completionID += 1
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func clearError() {
        lastErrorMessage = nil
    }

    /// Every model type in both containers; a new @Model must be added here
    /// or the nuke leaves its rows behind. The wipe is the app's own synced
    /// write, so it deposits a self-save credit like every other — but only
    /// when it deleted a synced row: a save that touches the local store
    /// alone posts no synced-store notification for the credit to swallow.
    private func deleteAllModelRows(modelContext: ModelContext) throws {
        var deletedSyncedRowCount = 0
        deletedSyncedRowCount += try Self.deleteAll(SubscriptionRecord.self, modelContext: modelContext)
        deletedSyncedRowCount += try Self.deleteAll(EpisodeProgressRecord.self, modelContext: modelContext)
        deletedSyncedRowCount += try Self.deleteAll(SyncTombstoneRecord.self, modelContext: modelContext)
        try Self.deleteAll(PodcastCacheRecord.self, modelContext: modelContext)
        try Self.deleteAll(EpisodeCacheRecord.self, modelContext: modelContext)
        try Self.deleteAll(RefreshLogRecord.self, modelContext: modelContext)
        try Self.deleteAll(LocalPreferenceRecord.self, modelContext: modelContext)
        try Self.deleteAll(EpisodeDownloadRecord.self, modelContext: modelContext)
        try Self.deleteAll(EpisodeTranscriptRecord.self, modelContext: modelContext)
        try Self.deleteAll(EpisodeAdAnalysisRecord.self, modelContext: modelContext)
        try Self.deleteAll(EpisodeTranscriptAnalysisRecord.self, modelContext: modelContext)
        try Self.deleteAll(AdFreePassQueueItemRecord.self, modelContext: modelContext)
        try Self.deleteAll(UpNextQueueItemRecord.self, modelContext: modelContext)
        if deletedSyncedRowCount > 0 {
            try library.saveSyncedStore(modelContext)
        } else {
            try modelContext.save()
        }
    }

    @discardableResult
    private static func deleteAll<Model: PersistentModel>(
        _ modelType: Model.Type,
        modelContext: ModelContext
    ) throws -> Int {
        let records = try modelContext.fetch(FetchDescriptor<Model>())
        for record in records {
            modelContext.delete(record)
        }
        return records.count
    }
}
