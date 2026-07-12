import Foundation

public struct RemoteWhisperModel: Codable, Sendable, Equatable {
    public var modelID: String
    public var version: String
    public var modelFolder: String
    public var tokenizerFolder: String
    public var totalByteCount: Int64
    public var treeSHA256: String
    public var files: [RemoteWhisperModelFile]

    public init(
        modelID: String,
        version: String,
        modelFolder: String,
        tokenizerFolder: String,
        totalByteCount: Int64,
        treeSHA256: String,
        files: [RemoteWhisperModelFile]
    ) {
        self.modelID = modelID
        self.version = version
        self.modelFolder = modelFolder
        self.tokenizerFolder = tokenizerFolder
        self.totalByteCount = totalByteCount
        self.treeSHA256 = treeSHA256
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case version
        case modelFolder = "model_folder"
        case tokenizerFolder = "tokenizer_folder"
        case totalByteCount = "total_byte_count"
        case treeSHA256 = "tree_sha256"
        case files
    }
}
