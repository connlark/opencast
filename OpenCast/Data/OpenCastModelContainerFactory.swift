import Foundation
import SwiftData

enum OpenCastModelContainerFactory {
    static let cloudKitContainerIdentifier = "iCloud.com.connor.opencast"

    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let syncedSchema = Schema([
            SubscriptionRecord.self,
            EpisodeProgressRecord.self
        ])
        let localSchema = Schema([
            PodcastCacheRecord.self,
            EpisodeCacheRecord.self,
            RefreshLogRecord.self,
            LocalPreferenceRecord.self,
            EpisodeDownloadRecord.self
        ])
        let fullSchema = Schema([
            SubscriptionRecord.self,
            EpisodeProgressRecord.self,
            PodcastCacheRecord.self,
            EpisodeCacheRecord.self,
            RefreshLogRecord.self,
            LocalPreferenceRecord.self,
            EpisodeDownloadRecord.self
        ])

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
