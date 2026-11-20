import Foundation

/// The explicit cases are a DEBUG benchmark surface and stay engine-strict, with no fallback.
enum AdFreePassTranscriptionEngine: String, Sendable, Equatable {
    case productDefault
    case selectedWhisperModel
    case whisperTiny
    case appleSpeech

    var isExplicitOverride: Bool {
        self != .productDefault
    }

    var logDescription: String {
        rawValue
    }

    nonisolated static func benchmarkValue(from value: String?) -> AdFreePassTranscriptionEngine? {
        guard let value else {
            return nil
        }

        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "apple", "apple-speech", "applespeech", "speech":
            return .appleSpeech
        case "tiny", "whisper-tiny", "whispertiny", "whisper_tiny":
            return .whisperTiny
        case "selected", "selected-whisper", "selectedwhispermodel":
            return .selectedWhisperModel
        default:
            return nil
        }
    }
}
