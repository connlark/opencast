import Foundation

/// One regular-file byte-count helper beside `OpenCastSHA256`. Resource
/// read errors propagate as thrown; metadata failing the regular-file
/// guard throws `NotARegularFile`, which call sites map into their local
/// error conventions.
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
