#if DEBUG
import Foundation

nonisolated enum TranscriptionProofEngine: String, Codable, Sendable, Equatable {
    case whisper
    case appleSpeech

    static func selected(arguments: Set<String>, environment: [String: String]) -> Self {
        if arguments.contains(TranscriptionProofRunner.appleSpeechRequestArgument) {
            return .appleSpeech
        }

        switch environment[TranscriptionProofRunner.engineEnvironmentKey] {
        case "apple-speech", "appleSpeech", "speech", "SpeechAnalyzer":
            return .appleSpeech
        default:
            return .whisper
        }
    }
}
#endif
