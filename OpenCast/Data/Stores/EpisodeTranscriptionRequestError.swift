import Foundation

enum EpisodeTranscriptionRequestError: LocalizedError {
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .operationFailed(let message):
            message
        }
    }
}
