import Foundation
import SwiftData

enum OpenCastModelContainerFactory {
    nonisolated static let cloudKitContainerIdentifier = "iCloud.com.connor.opencast"
    static let syncedConfigurationName = "SyncedUserData"
    static let localConfigurationName = "LocalDeviceData"

    static var syncedSchema: Schema {
        Schema([
            SubscriptionRecord.self,
            EpisodeProgressRecord.self,
            SyncTombstoneRecord.self,
            PlaylistRecord.self,
            PlaylistItemRecord.self,
            PlaylistTombstoneRecord.self
        ])
    }

    static var localSchema: Schema {
        Schema([
            PodcastCacheRecord.self,
            EpisodeCacheRecord.self,
            RefreshLogRecord.self,
            LocalPreferenceRecord.self,
            EpisodeDownloadRecord.self,
            EpisodeTranscriptRecord.self,
            EpisodeAdAnalysisRecord.self,
            EpisodeTranscriptAnalysisRecord.self,
            AdFreePassQueueItemRecord.self,
            UpNextQueueItemRecord.self,
            EpisodeNoteRecord.self
        ])
    }

    static var fullSchema: Schema {
        Schema([
            SubscriptionRecord.self,
            EpisodeProgressRecord.self,
            SyncTombstoneRecord.self,
            PlaylistRecord.self,
            PlaylistItemRecord.self,
            PlaylistTombstoneRecord.self,
            PodcastCacheRecord.self,
            EpisodeCacheRecord.self,
            RefreshLogRecord.self,
            LocalPreferenceRecord.self,
            EpisodeDownloadRecord.self,
            EpisodeTranscriptRecord.self,
            EpisodeAdAnalysisRecord.self,
            EpisodeTranscriptAnalysisRecord.self,
            AdFreePassQueueItemRecord.self,
            UpNextQueueItemRecord.self,
            EpisodeNoteRecord.self
        ])
    }

    /// Stores open through the explicit-URL configuration, so SwiftData's App Group discovery,
    /// which copies a store into the group, is never consulted.
    static func make(inMemory: Bool = false, layout: ModelStoreLayout = .current()) throws -> ModelContainer {
        try make(
            inMemory: inMemory,
            layout: layout,
            syncedCloudKitDatabase: .private(cloudKitContainerIdentifier)
        )
    }

    /// Tests pass `.none`: a mirrored store would share the CloudKit container and zone with the
    /// host app's live store.
    static func make(
        inMemory: Bool,
        layout: ModelStoreLayout,
        syncedCloudKitDatabase: ModelConfiguration.CloudKitDatabase
    ) throws -> ModelContainer {
        let configurations = configurations(
            inMemory: inMemory,
            layout: layout,
            syncedCloudKitDatabase: syncedCloudKitDatabase
        )
        if !inMemory {
            // A fresh install resolves to an app container whose
            // Application Support may not exist yet.
            for configuration in configurations {
                try FileManager.default.createDirectory(
                    at: configuration.url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
        }
        return try ModelContainer(for: fullSchema, configurations: configurations)
    }

    /// Synced then local.
    private static func configurations(
        inMemory: Bool,
        layout: ModelStoreLayout,
        syncedCloudKitDatabase: ModelConfiguration.CloudKitDatabase
    ) -> [ModelConfiguration] {
        if inMemory {
            return [
                ModelConfiguration(
                    syncedConfigurationName,
                    schema: syncedSchema,
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                ),
                ModelConfiguration(
                    localConfigurationName,
                    schema: localSchema,
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                )
            ]
        }
        return [
            ModelConfiguration(
                syncedConfigurationName,
                schema: syncedSchema,
                url: layout.synced.resolvedURL,
                cloudKitDatabase: syncedCloudKitDatabase
            ),
            ModelConfiguration(
                localConfigurationName,
                schema: localSchema,
                url: layout.local.resolvedURL,
                cloudKitDatabase: .none
            )
        ]
    }
}
