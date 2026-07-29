import Foundation

enum EpisodeTranscriptionError: LocalizedError, Equatable {
    case downloadNotComplete
    case mismatchedDownloadRecord
    case missingDownloadedFile
    case missingSpeechModel
    case anotherJobActive
    case invalidAudioDuration
    case transcriptDocumentMissing

    var errorDescription: String? {
        switch self {
        case .downloadNotComplete:
            "Download the episode before generating a transcript."
        case .mismatchedDownloadRecord:
            "The completed download does not match this episode."
        case .missingDownloadedFile:
            "The downloaded audio file is missing."
        case .missingSpeechModel:
            "Install the speech model before generating a transcript."
        case .anotherJobActive:
            "Another transcript is already being generated."
        case .invalidAudioDuration:
            "The downloaded audio duration could not be read."
        case .transcriptDocumentMissing:
            "The transcript document is missing."
        }
    }
}
