import Foundation

public enum OpenCastFileByteCount {
    public struct NotARegularFile: Error, Sendable {
        public let path: String
    }

    public static func byteCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            throw NotARegularFile(path: url.path)
        }
        return Int64(fileSize)
    }

    @concurrent
    public static func byteCountOffCaller(at url: URL) async throws -> Int64 {
        try byteCount(at: url)
    }
}
