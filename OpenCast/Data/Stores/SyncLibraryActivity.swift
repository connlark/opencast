import Foundation

enum SyncLibraryActivity: Equatable, Sendable {
    case idle
    case checkingAccount
    case waitingForImports
    case reloading
    case repairingDuplicates
    case syncingFeeds
    case failed(String)

    var shouldDisplay: Bool {
        self != .idle
    }

    var showsProgress: Bool {
        switch self {
        case .checkingAccount, .waitingForImports, .reloading, .repairingDuplicates, .syncingFeeds:
            true
        case .idle, .failed:
            false
        }
    }

    var title: String {
        switch self {
        case .idle:
            "Sync Idle"
        case .checkingAccount:
            "Checking iCloud"
        case .waitingForImports:
            "Syncing with iCloud"
        case .reloading:
            "Updating Library"
        case .repairingDuplicates:
            "Cleaning Up Sync"
        case .syncingFeeds:
            "Syncing Feeds"
        case .failed:
            "Sync Needs Attention"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            "Subscriptions and listening progress are up to date."
        case .checkingAccount:
            "Checking whether iCloud sync is available on this device."
        case .waitingForImports:
            "Looking for subscriptions and progress saved in your iCloud account."
        case .reloading:
            "Applying imported subscription and progress changes."
        case .repairingDuplicates:
            "Merging duplicate subscription or progress records from other devices."
        case .syncingFeeds:
            "Fetching the latest episodes for your synced subscriptions."
        case .failed(let message):
            message.isEmpty
                ? "The latest sync check could not finish."
                : message
        }
    }

    var systemImage: String {
        switch self {
        case .failed:
            "exclamationmark.icloud"
        case .idle, .checkingAccount, .waitingForImports, .reloading, .repairingDuplicates, .syncingFeeds:
            "icloud"
        }
    }
}
