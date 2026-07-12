import Foundation

public struct OpenCastTranscriptionRequest: Sendable {
    public static let defaultClipDuration: TimeInterval = 30
    public static let maximumClipDuration: TimeInterval = 120

    public var audioFileURL: URL
    public var clipStart: TimeInterval
    public var clipDuration: TimeInterval
    public var languageCode: String

    public init(
        audioFileURL: URL,
        clipStart: TimeInterval = 0,
        clipDuration: TimeInterval = Self.defaultClipDuration,
        languageCode: String = "en"
    ) {
        self.audioFileURL = audioFileURL
        self.clipStart = clipStart
        self.clipDuration = clipDuration
        self.languageCode = languageCode
    }
}
