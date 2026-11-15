import Foundation

/// How a completed download's file stops matching its record after the
/// stores loaded: gone, or of another size. `driftedUnhashed` is `drifted`
/// for a test that seeds the record without a hash.
enum DownloadFileDefect: CaseIterable, Sendable {
    case missing
    case drifted
    case driftedUnhashed

    func apply(to fileURL: URL) throws {
        switch self {
        case .missing:
            try FileManager.default.removeItem(at: fileURL)
        case .drifted, .driftedUnhashed:
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(" and more".utf8))
            try handle.close()
        }
    }
}
