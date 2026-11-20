import Foundation
import Observation
import SwiftData

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
    @ObservationIgnored private let transcriptRecaps: TranscriptRecapCache
    @ObservationIgnored private let customSkipSoundFiles: CustomSkipSoundFiles
    @ObservationIgnored var prepareRuntime: () async -> Void = {}
    @ObservationIgnored var deregisterServices: () async -> Void = {}
    @ObservationIgnored private let appAttestSuspension: AppAttestSuspension
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
        siriMediaDiscovery: SiriMediaDiscovery,
        transcriptRecaps: TranscriptRecapCache = TranscriptRecapCache(),
        customSkipSoundFiles: CustomSkipSoundFiles = CustomSkipSoundFiles(),
        appAttestSuspension: AppAttestSuspension = .shared
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
        self.transcriptRecaps = transcriptRecaps
        self.customSkipSoundFiles = customSkipSoundFiles
        self.appAttestSuspension = appAttestSuspension
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
            await deregisterServices()
            let siriPodcastIDs = library.activePodcastIDs
            let siriPlaylistIDs = Set(try modelContext.fetch(FetchDescriptor<PlaylistRecord>()).map(\.playlistID))
            try deleteAllModelRows(modelContext: modelContext)
            siriMediaDiscovery.deleteDonations(forPodcastIDs: siriPodcastIDs)
            siriMediaDiscovery.deleteDonations(forPlaylistIDs: siriPlaylistIDs)
            // Nothing that suspends may sit between the row wipe and resetRuntime's playback
            // unload: playback flushes progress at every await, and a flush here would re-insert
            // a wiped row. Progress writes carry no write-generation token; this order guards them.
            await resetRuntime(modelContext)
            try await library.deleteAllLocalCache()
            try await cacheController.clearCachesNow()
            try transcriptRecaps.removeAll()
            try customSkipSoundFiles.removeAll()
            completionID += 1
        } catch {
            appAttestSuspension.resume()
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    func clearError() {
        lastErrorMessage = nil
    }

    /// A new @Model must be added here or the nuke leaves its rows behind. Only a wipe that deleted
    /// a synced row saves through `saveSyncedStore`: a local-only save posts no synced-store
    /// notification for its self-save credit to swallow.
    private func deleteAllModelRows(modelContext: ModelContext) throws {
        var deletedSyncedRowCount = 0
        deletedSyncedRowCount += try Self.deleteAll(SubscriptionRecord.self, modelContext: modelContext)
        deletedSyncedRowCount += try Self.deleteAll(EpisodeProgressRecord.self, modelContext: modelContext)
        deletedSyncedRowCount += try Self.deleteAll(SyncTombstoneRecord.self, modelContext: modelContext)
        deletedSyncedRowCount += try Self.deleteAll(PlaylistRecord.self, modelContext: modelContext)
        deletedSyncedRowCount += try Self.deleteAll(PlaylistItemRecord.self, modelContext: modelContext)
        deletedSyncedRowCount += try Self.deleteAll(PlaylistTombstoneRecord.self, modelContext: modelContext)
        try Self.deleteAll(PodcastCacheRecord.self, modelContext: modelContext)
        try Self.deleteAll(EpisodeCacheRecord.self, modelContext: modelContext)
        try Self.deleteAll(RefreshLogRecord.self, modelContext: modelContext)
        try Self.deleteAll(LocalPreferenceRecord.self, modelContext: modelContext)
        try Self.deleteAll(EpisodeDownloadRecord.self, modelContext: modelContext)
        try Self.deleteAll(EpisodeTranscriptRecord.self, modelContext: modelContext)
        try Self.deleteAll(EpisodeAdAnalysisRecord.self, modelContext: modelContext)
        try Self.deleteAll(EpisodeTranscriptAnalysisRecord.self, modelContext: modelContext)
        try Self.deleteAll(EpisodeNoteRecord.self, modelContext: modelContext)
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
