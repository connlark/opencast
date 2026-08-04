import Foundation

enum OPMLImportFileReadError: LocalizedError, Sendable {
    case fileTooLarge
    case tooManyFeeds(count: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            "OPML files larger than 10 MB are not supported."
        case .tooManyFeeds(let count, let limit):
            "This file lists \(count) unique feeds; imports are capped at \(limit). Split the file and import it in parts."
        }
    }
}
