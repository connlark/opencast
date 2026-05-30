import Foundation

enum EpisodeDownloadError: LocalizedError {
    case invalidAudioURL
    case invalidDownloadedRecord
    case missingDownloadedFile
    case downloadNotComplete
    case interrupted
    case invalidHTTPStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAudioURL:
            "This episode does not have a playable audio URL."
        case .invalidDownloadedRecord:
            "This downloaded file does not match the episode."
        case .missingDownloadedFile:
            "The downloaded file is missing from local storage."
        case .downloadNotComplete:
            "The episode has not finished downloading."
        case .interrupted:
            "Download was interrupted."
        case .invalidHTTPStatus(let statusCode):
            "The server returned HTTP \(statusCode)."
        }
    }
}
