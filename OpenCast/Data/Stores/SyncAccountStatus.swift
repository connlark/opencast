import Foundation

enum SyncAccountStatus: Equatable, Sendable {
    case notChecked
    case checking
    case available
    case noAccount
    case restricted
    case couldNotDetermine
    case temporarilyUnavailable(String)

    var displayName: String {
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

    var detail: String? {
        switch self {
        case .available:
            nil
        case .noAccount:
            "Sign in to iCloud to sync subscriptions and episode progress. OpenCast still works locally on this device."
        case .restricted:
            "This device or account restricts iCloud access. OpenCast still works locally on this device."
        case .couldNotDetermine:
            "OpenCast could not determine iCloud status. Local playback, downloads, and settings are still available."
        case .temporarilyUnavailable(let message):
            message.isEmpty
                ? "iCloud status is temporarily unavailable. OpenCast still works locally on this device."
                : "\(message) OpenCast still works locally on this device."
        case .notChecked, .checking:
            nil
        }
    }
}
