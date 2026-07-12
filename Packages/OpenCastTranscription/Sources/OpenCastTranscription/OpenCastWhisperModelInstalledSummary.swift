import Foundation

public struct OpenCastWhisperModelInstalledSummary: Sendable, Equatable {
    public var modelIdentifier: String
    public var version: String
    public var totalByteCount: Int64
    public var treeSHA256: String

    public init(
        modelIdentifier: String,
        version: String,
        totalByteCount: Int64,
        treeSHA256: String
    ) {
        self.modelIdentifier = modelIdentifier
        self.version = version
        self.totalByteCount = totalByteCount
        self.treeSHA256 = treeSHA256
    }
}
