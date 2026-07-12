import Foundation
import SwiftData

enum OpenCastModelContainerFactory {
    static let cloudKitContainerIdentifier = "iCloud.com.connor.opencast"

    static var syncedSchema: Schema {
        Schema([
            SubscriptionRecord.self,
            EpisodeProgressRecord.self
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
            AdFreePassQueueItemRecord.self
        ])
    }

    static var fullSchema: Schema {
        Schema([
            SubscriptionRecord.self,
            EpisodeProgressRecord.self,
            PodcastCacheRecord.self,
            EpisodeCacheRecord.self,
            RefreshLogRecord.self,
            LocalPreferenceRecord.self,
            EpisodeDownloadRecord.self,
            EpisodeTranscriptRecord.self,
            EpisodeAdAnalysisRecord.self,
            AdFreePassQueueItemRecord.self
        ])
    }

    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let syncedCloudKitDatabase: ModelConfiguration.CloudKitDatabase = inMemory
            ? .none
            : .private(cloudKitContainerIdentifier)

        let syncedConfiguration = ModelConfiguration(
            "SyncedUserData",
            schema: syncedSchema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: syncedCloudKitDatabase
        )
        let localConfiguration = ModelConfiguration(
            "LocalDeviceData",
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
