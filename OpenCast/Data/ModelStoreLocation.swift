import Foundation

/// One SwiftData store's two possible homes and the one this launch opens.
nonisolated struct ModelStoreLocation: Hashable, Sendable {
    /// `OpenCastModelContainerFactory.syncedConfigurationName` or `.localConfigurationName`.
    let configurationName: String
    /// The App Group location every launch since f873d317 has opened:
    /// `ModelConfiguration(name, schema:, groupContainer: .identifier(ModelStoreLayout.appGroupIdentifier)).url`.
    let groupURL: URL
    /// The app data container location:
    /// `ModelConfiguration(name, schema:, groupContainer: .none).url`.
    let appURL: URL
    /// The URL the container opens this launch. Equals `groupURL` until a
    /// relocation resolves it.
    var resolvedURL: URL
}
