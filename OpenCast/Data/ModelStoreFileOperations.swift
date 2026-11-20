import Foundation

nonisolated protocol ModelStoreFileOperations: Sendable {
    /// nil only when nothing exists at `url` (`stat` answers ENOENT); any
    /// other failure throws.
    func status(at url: URL) throws -> ModelStoreFileStatus?
    /// Dot-entries included, unsorted. Throws when the directory is absent or unreadable.
    func entryNames(in directory: URL) throws -> [String]
    /// Creates `url` with intermediate directories; an existing directory
    /// is not an error.
    func createDirectory(at url: URL) throws
    /// An absent item is not an error; any other failure throws, even partway through a tree.
    func removeItem(at url: URL) throws
    /// `FileManager.copyItem` semantics: the destination must not exist. Throws on any failure,
    /// even partway through a tree.
    func copyItem(at source: URL, to destination: URL) throws
    /// `rename(2)`. Every errno, `EXDEV` included, throws.
    func rename(_ source: URL, to destination: URL) throws
}
