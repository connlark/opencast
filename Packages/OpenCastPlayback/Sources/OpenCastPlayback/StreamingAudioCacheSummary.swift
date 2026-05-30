import Foundation

public nonisolated struct StreamingAudioCacheSummary: Equatable, Sendable {
    public var byteCount: Int64
    public var fileCount: Int

    public init(byteCount: Int64, fileCount: Int) {
        self.byteCount = byteCount
        self.fileCount = fileCount
    }
}
