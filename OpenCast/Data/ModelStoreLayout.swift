import Foundation
import SwiftData

nonisolated struct ModelStoreLayout: Hashable, Sendable {
    static let appGroupIdentifier = "group.com.connor.opencast"

    var synced: ModelStoreLocation
    var local: ModelStoreLocation

    var localStoreURL: URL { local.resolvedURL }

    /// Both URLs come from SwiftData's own `ModelConfiguration` computation, never a hand-built
    /// path, and building them creates no file. Every `resolvedURL` starts at its `groupURL`.
    @MainActor
    static func current() -> ModelStoreLayout {
        ModelStoreLayout(
            synced: location(
                OpenCastModelContainerFactory.syncedConfigurationName,
                schema: OpenCastModelContainerFactory.syncedSchema,
                cloudKitDatabase: .private(OpenCastModelContainerFactory.cloudKitContainerIdentifier)
            ),
            local: location(
                OpenCastModelContainerFactory.localConfigurationName,
                schema: OpenCastModelContainerFactory.localSchema,
                cloudKitDatabase: .none
            )
        )
    }

    /// Each configuration carries the factory's CloudKit database, so its URL is the one the
    /// factory opens.
    private static func location(
        _ name: String,
        schema: Schema,
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase
    ) -> ModelStoreLocation {
        let groupURL = ModelConfiguration(
            name,
            schema: schema,
            groupContainer: .identifier(appGroupIdentifier),
            cloudKitDatabase: cloudKitDatabase
        ).url
        let appURL = ModelConfiguration(
            name,
            schema: schema,
            groupContainer: .none,
            cloudKitDatabase: cloudKitDatabase
        ).url
        return ModelStoreLocation(
            configurationName: name,
            groupURL: groupURL,
            appURL: appURL,
            resolvedURL: groupURL
        )
    }
}
