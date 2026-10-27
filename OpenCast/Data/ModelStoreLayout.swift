import Foundation
import SwiftData

nonisolated struct ModelStoreLayout: Hashable, Sendable {
    static let appGroupIdentifier = "group.com.connor.opencast"

    var synced: ModelStoreLocation
    var local: ModelStoreLocation

    /// Where the device-local store lives this launch (`local.resolvedURL`).
    var localStoreURL: URL { local.resolvedURL }

    /// Both URLs per store from SwiftData's own computation (the two
    /// `ModelConfiguration` forms above, with the factory's schemas); never a
    /// hand-built path. Constructing them creates no file and no directory.
    /// Every `resolvedURL` starts at its `groupURL`.
    ///
    /// Main-actor isolated because the factory's names and schemas are.
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

    /// The configurations carry the factory's CloudKit database so each one
    /// is the configuration the factory opened before this layout existed,
    /// with only the group container made explicit.
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
