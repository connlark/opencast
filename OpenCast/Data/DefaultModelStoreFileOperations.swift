import Darwin
import Foundation

/// `FileManager` plus POSIX (`stat`, `rename`).
nonisolated struct DefaultModelStoreFileOperations: ModelStoreFileOperations {
    init() {}

    func status(at url: URL) throws -> ModelStoreFileStatus? {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else {
            let code = errno
            if code == ENOENT {
                return nil
            }
            throw Self.posixError(code)
        }
        return ModelStoreFileStatus(
            isDirectory: info.st_mode & S_IFMT == S_IFDIR,
            size: Int(info.st_size),
            deviceNumber: Int(info.st_dev)
        )
    }

    func entryNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func removeItem(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func rename(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path(percentEncoded: false), destination.path(percentEncoded: false)) == 0 else {
            throw Self.posixError(errno)
        }
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
