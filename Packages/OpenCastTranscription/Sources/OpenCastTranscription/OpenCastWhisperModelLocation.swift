import Foundation

public struct OpenCastWhisperModelLocation: Sendable {
    public var modelIdentifier: String
    public var modelFolder: URL
    public var tokenizerFolder: URL

    public init(modelIdentifier: String, modelFolder: URL, tokenizerFolder: URL) {
        self.modelIdentifier = modelIdentifier
        self.modelFolder = modelFolder
        self.tokenizerFolder = tokenizerFolder
    }
}
