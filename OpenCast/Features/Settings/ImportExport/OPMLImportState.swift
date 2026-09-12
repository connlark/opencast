import Foundation

enum OPMLImportState: Equatable {
    case idle
    case importing
    case imported(OPMLImportResult)
    case failed(String)

    var isImporting: Bool {
        if case .importing = self {
            return true
        }

        return false
    }
}
