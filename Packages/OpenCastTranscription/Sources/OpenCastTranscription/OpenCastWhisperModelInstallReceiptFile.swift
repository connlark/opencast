import Foundation

struct OpenCastWhisperModelInstallReceiptFile: Codable, Sendable, Equatable {
    var path: String
    var byteCount: Int64
    var sha256: String

    init(path: String, byteCount: Int64, sha256: String) {
        self.path = path
        self.byteCount = byteCount
        self.sha256 = sha256.lowercased()
    }

    init(file: RemoteWhisperModelFile) {
        self.init(path: file.path, byteCount: file.byteCount, sha256: file.sha256)
    }

    enum CodingKeys: String, CodingKey {
        case path
        case byteCount = "byte_count"
        case sha256
    }
}
