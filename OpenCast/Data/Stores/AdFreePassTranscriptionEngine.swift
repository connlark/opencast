import Foundation

/// The requested transcription engine for an Ad-Free Pass run.
/// `.productDefault` resolves Apple-first via `EpisodeTranscriptionPlanResolver`
/// (decision 1); the explicit cases are the permanent DEBUG benchmark/control
/// surface and stay engine-strict.
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
