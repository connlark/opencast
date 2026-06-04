import Foundation

enum DataNukeError: LocalizedError {
    case iCloudUnavailable(SyncAccountStatus)

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable(let status):
            if let detail = status.detail {
                return "Nuke canceled because iCloud is not available. Current status: \(status.displayName). \(detail)"
            }

            return "Nuke canceled because iCloud is not available. Current status: \(status.displayName)."
        }
    }
}
