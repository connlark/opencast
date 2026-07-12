import Foundation

struct OpenCastWhisperModelInstallReceipt: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var modelIdentifier: String
    var version: String
    var treeSHA256: String
    var totalByteCount: Int64
    var files: [OpenCastWhisperModelInstallReceiptFile]

    init(model: RemoteWhisperModel) {
        schemaVersion = 1
        modelIdentifier = model.modelID
        version = model.version
        treeSHA256 = model.treeSHA256.lowercased()
        totalByteCount = model.totalByteCount
        files = model.files.map(OpenCastWhisperModelInstallReceiptFile.init(file:))
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case modelIdentifier = "model_id"
        case version
        case treeSHA256 = "tree_sha256"
        case totalByteCount = "total_byte_count"
        case files
    }
}
