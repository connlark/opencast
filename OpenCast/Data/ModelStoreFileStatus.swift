import Foundation

nonisolated struct ModelStoreFileStatus: Hashable, Sendable {
    let isDirectory: Bool
    /// `st_size` in bytes.
    let size: Int
    /// `st_dev` (`FileAttributeKey.systemNumber`).
    let deviceNumber: Int
}
