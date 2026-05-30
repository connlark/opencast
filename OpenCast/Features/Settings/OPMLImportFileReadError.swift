import Foundation

enum OPMLImportFileReadError: LocalizedError, Sendable {
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            "OPML files larger than 10 MB are not supported."
        }
    }
}
