import Foundation
import Observation
import SwiftData

@Observable
final class SyncStatusStore {
    private static let accountStatusRefreshInterval: TimeInterval = 30

    private(set) var accountStatus: SyncAccountStatus = .notChecked
    private(set) var isRepairingDuplicates = false
    private(set) var lastRepairResult: SyncRepairResult?
    private(set) var lastRepairErrorMessage: String?

    @ObservationIgnored private let accountStatusProvider: any CloudKitAccountStatusProviding
    @ObservationIgnored private var isRefreshingAccountStatus = false
    @ObservationIgnored private var lastAccountStatusRefreshAt: Date?

    init(accountStatusProvider: any CloudKitAccountStatusProviding = CloudKitAccountStatusProvider()) {
        self.accountStatusProvider = accountStatusProvider
    }

    func refreshAccountStatus() async {
        guard !isRefreshingAccountStatus else {
            return
        }
        guard shouldRefreshAccountStatus() else {
            return
        }

        isRefreshingAccountStatus = true
        if accountStatus == .notChecked {
            updateAccountStatus(.checking)
        }

        defer {
            isRefreshingAccountStatus = false
        }

        do {
            let refreshedStatus = try await accountStatusProvider.accountStatus()
            updateAccountStatus(refreshedStatus)
            lastAccountStatusRefreshAt = .now
        } catch is CancellationError {
            if accountStatus == .checking {
                updateAccountStatus(.notChecked)
            }
        } catch {
            updateAccountStatus(.temporarilyUnavailable(error.localizedDescription))
            lastAccountStatusRefreshAt = .now
        }
    }

    func repairDuplicates(modelContext: ModelContext, libraryStore: LibraryStore) async {
        guard !isRepairingDuplicates else {
            return
        }

        isRepairingDuplicates = true
        defer {
            isRepairingDuplicates = false
        }

        await Task.yield()

        do {
            lastRepairResult = try libraryStore.repairSyncDuplicates(modelContext: modelContext)
            lastRepairErrorMessage = nil
        } catch {
            lastRepairResult = nil
            lastRepairErrorMessage = error.localizedDescription
        }
    }

    private func shouldRefreshAccountStatus() -> Bool {
        guard let lastAccountStatusRefreshAt else {
            return true
        }

        return Date.now.timeIntervalSince(lastAccountStatusRefreshAt) >= Self.accountStatusRefreshInterval
    }

    private func updateAccountStatus(_ status: SyncAccountStatus) {
        if accountStatus != status {
            accountStatus = status
        }
    }
}
