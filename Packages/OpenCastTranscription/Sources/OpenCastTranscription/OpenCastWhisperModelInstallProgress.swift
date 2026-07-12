import Foundation

public typealias OpenCastWhisperModelInstallProgressHandler = @Sendable (OpenCastWhisperModelInstallProgress) -> Void

public struct OpenCastWhisperModelInstallProgress: Sendable, Equatable {
    public var modelIdentifier: String
    public var version: String
    public var completedFileCount: Int
    public var totalFileCount: Int
    public var completedByteCount: Int64
    public var totalByteCount: Int64
    public var currentFilePath: String?

    public init(
        modelIdentifier: String,
        version: String,
        completedFileCount: Int,
        totalFileCount: Int,
        completedByteCount: Int64,
        totalByteCount: Int64,
        currentFilePath: String?
    ) {
        self.modelIdentifier = modelIdentifier
        self.version = version
        self.completedFileCount = completedFileCount
        self.totalFileCount = totalFileCount
        self.completedByteCount = completedByteCount
        self.totalByteCount = totalByteCount
        self.currentFilePath = currentFilePath
    }
}
