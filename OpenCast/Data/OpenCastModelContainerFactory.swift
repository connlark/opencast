import Foundation
import SwiftData

enum OpenCastModelContainerFactory {
    static let cloudKitContainerIdentifier = "iCloud.com.connor.opencast"
    static let syncedConfigurationName = "SyncedUserData"
    static let localConfigurationName = "LocalDeviceData"

    static var syncedSchema: Schema {
        Schema([
            SubscriptionRecord.self,
            EpisodeProgressRecord.self,
            SyncTombstoneRecord.self
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
            AdFreePassQueueItemRecord.self,
            UpNextQueueItemRecord.self
        ])
    }

    static var fullSchema: Schema {
        Schema([
            SubscriptionRecord.self,
            EpisodeProgressRecord.self,
            SyncTombstoneRecord.self,
            PodcastCacheRecord.self,
            EpisodeCacheRecord.self,
            RefreshLogRecord.self,
            LocalPreferenceRecord.self,
            EpisodeDownloadRecord.self,
            EpisodeTranscriptRecord.self,
            EpisodeAdAnalysisRecord.self,
            AdFreePassQueueItemRecord.self,
            UpNextQueueItemRecord.self
        ])
    }

    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let syncedCloudKitDatabase: ModelConfiguration.CloudKitDatabase = inMemory
            ? .none
            : .private(cloudKitContainerIdentifier)

        let syncedConfiguration = ModelConfiguration(
            syncedConfigurationName,
            schema: syncedSchema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: syncedCloudKitDatabase
        )
        let localConfiguration = ModelConfiguration(
            localConfigurationName,
            schema: localSchema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )

        return try ModelContainer(
            for: fullSchema,
            configurations: [syncedConfiguration, localConfiguration]
        )
    }
}
