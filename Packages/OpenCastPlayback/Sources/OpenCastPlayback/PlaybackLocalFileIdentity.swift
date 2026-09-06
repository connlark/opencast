import Foundation

/// Captures the file generation loaded by an item, including replacements
/// that reuse the same download URL.
nonisolated struct PlaybackLocalFileIdentity: Equatable {
    let fileNumber: UInt64
    let byteCount: Int64
    let modifiedAt: Date

    init?(at fileURL: URL) {
        guard fileURL.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileNumber = attributes[.systemFileNumber] as? NSNumber,
              let byteCount = attributes[.size] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        self.fileNumber = fileNumber.uint64Value
        self.byteCount = byteCount.int64Value
        self.modifiedAt = modifiedAt
    }
}
