import Foundation

enum SyncAccountStatus: Equatable, Sendable {
    case notChecked
    case checking
    case available
    case noAccount
    case restricted
    case couldNotDetermine
    case temporarilyUnavailable(String)

    nonisolated var displayName: String {
        switch self {
        case .notChecked:
            "Not Checked"
        case .checking:
            "Checking"
        case .available:
            "Available"
        case .noAccount:
            "No iCloud Account"
        case .restricted:
            "Restricted"
        case .couldNotDetermine:
            "Could Not Determine"
        case .temporarilyUnavailable:
            "Temporarily Unavailable"
        }
    }

    nonisolated var detail: String? {
        switch self {
        case .available:
            nil
        case .noAccount:
            "Sign in to iCloud to sync subscriptions and episode progress. opencast still works locally on this device."
        case .restricted:
            "This device or account restricts iCloud access. opencast still works locally on this device."
        case .couldNotDetermine:
            "opencast could not determine iCloud status. Local playback, downloads, and settings are still available."
        case .temporarilyUnavailable(let message):
            message.isEmpty
                ? "iCloud status is temporarily unavailable. opencast still works locally on this device."
                : "\(message) opencast still works locally on this device."
        case .notChecked, .checking:
            nil
        }
    }
}
