import Foundation

nonisolated struct ModelStoreLocation: Hashable, Sendable {
    /// `OpenCastModelContainerFactory.syncedConfigurationName` or `.localConfigurationName`.
    let configurationName: String
    let groupURL: URL
    let appURL: URL
    /// Equals `groupURL` until a relocation resolves it.
    var resolvedURL: URL
}
