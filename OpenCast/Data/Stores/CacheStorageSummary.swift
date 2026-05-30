import Foundation

nonisolated struct CacheStorageSummary: Equatable, Sendable {
    var byteCount: Int64
    var fileCount: Int

    static let empty = CacheStorageSummary(byteCount: 0, fileCount: 0)

    var formattedByteCount: String {
        byteCount.formatted(.byteCount(style: .file))
    }

    var storageDescription: String {
        guard byteCount > 0 else {
            return "None"
        }

        return formattedByteCount
    }
}
