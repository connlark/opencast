import Foundation

public enum OpenCastWhisperModel: String, CaseIterable, Sendable {
    case tinyEnglish = "openai_whisper-tiny.en"
    case largeV3 = "openai_whisper-large-v3-v20240930_626MB"

    public init?(commandLineValue value: String) {
        switch value {
        case "tiny", "tiny.en", Self.tinyEnglish.rawValue:
            self = .tinyEnglish
        case "large", "large-v3", Self.largeV3.rawValue:
            self = .largeV3
        default:
            return nil
        }
    }

    public var defaultRemoteVersion: String {
        switch self {
        case .tinyEnglish:
            "20260701_75MB-v1"
        case .largeV3:
            "20240930_626MB-v1"
        }
    }
}
