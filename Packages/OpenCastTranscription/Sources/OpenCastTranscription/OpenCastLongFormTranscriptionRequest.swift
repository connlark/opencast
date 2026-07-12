import Foundation

public struct OpenCastLongFormTranscriptionRequest: Sendable, Equatable {
    public var audioFileURL: URL
    public var languageCode: String
    public var resumeStart: TimeInterval?
    /// Optional decode-window end for benchmarks; production runs leave this
    /// nil and decode to the end of the audio.
    public var clipEnd: TimeInterval?
    public var sourceAudioURL: String
    public var sourceFileByteCount: Int64
    public var sourceFileSHA256: String
    public var modelIdentifier: String
    public var modelVersion: String
    public var modelTreeSHA256: String

    public init(
        audioFileURL: URL,
        languageCode: String = "en",
        resumeStart: TimeInterval? = nil,
        clipEnd: TimeInterval? = nil,
        sourceAudioURL: String,
        sourceFileByteCount: Int64,
        sourceFileSHA256: String,
        modelIdentifier: String,
        modelVersion: String,
        modelTreeSHA256: String
    ) {
        self.audioFileURL = audioFileURL
        self.languageCode = languageCode
        self.resumeStart = resumeStart
        self.clipEnd = clipEnd
        self.sourceAudioURL = sourceAudioURL
        self.sourceFileByteCount = sourceFileByteCount
        self.sourceFileSHA256 = sourceFileSHA256
        self.modelIdentifier = modelIdentifier
        self.modelVersion = modelVersion
        self.modelTreeSHA256 = modelTreeSHA256
    }
}
