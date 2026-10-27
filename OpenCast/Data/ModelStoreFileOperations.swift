import Foundation

/// The file-system seam the relocation goes through, so a test can fail
/// each probe and each mutation, including partway through a tree.
nonisolated protocol ModelStoreFileOperations: Sendable {
    /// nil only when nothing exists at `url` (`stat` answers ENOENT); any
    /// other failure throws.
    func status(at url: URL) throws -> ModelStoreFileStatus?
    /// Every entry name in `directory`, dot-entries included, unsorted.
    /// Throws when the directory is absent or unreadable.
    func entryNames(in directory: URL) throws -> [String]
    /// Creates `url` with intermediate directories; an existing directory
    /// is not an error.
    func createDirectory(at url: URL) throws
    /// Removes a file or a whole directory tree. An absent item is not an
    /// error; any other failure throws, including one partway through a tree.
    func removeItem(at url: URL) throws
    /// Copies a file or a whole directory tree (`FileManager.copyItem`
    /// semantics; the destination must not exist). Throws on any failure,
    /// including one partway through a tree.
    func copyItem(at source: URL, to destination: URL) throws
    /// `rename(2)`. Every errno, `EXDEV` included, throws.
    func rename(_ source: URL, to destination: URL) throws
}
