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
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var accountStatusRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastAccountStatusRefreshAt: Date?

    init(
        accountStatusProvider: any CloudKitAccountStatusProviding = CloudKitAccountStatusProvider(),
        now: @escaping () -> Date = { Date.now }
    ) {
        self.accountStatusProvider = accountStatusProvider
        self.now = now
    }

    @discardableResult
    func refreshAccountStatus(force: Bool = false) async -> SyncAccountStatus {
        if let accountStatusRefreshTask {
            await accountStatusRefreshTask.value
            return accountStatus
        }

        guard force || shouldRefreshAccountStatus() else {
            return accountStatus
        }

        let task = Task { [weak self] in
            guard let self else {
                return
            }

            await self.performAccountStatusRefresh()
        }
        accountStatusRefreshTask = task
        await task.value
        return accountStatus
    }

    private func performAccountStatusRefresh() async {
        if accountStatus == .notChecked {
            updateAccountStatus(.checking)
        }

        defer {
            accountStatusRefreshTask = nil
        }

        do {
            let refreshedStatus = try await accountStatusProvider.accountStatus()
            updateAccountStatus(refreshedStatus)
            lastAccountStatusRefreshAt = now()
        } catch is CancellationError {
            if accountStatus == .checking {
                updateAccountStatus(.notChecked)
            }
        } catch {
            updateAccountStatus(.temporarilyUnavailable(error.localizedDescription))
            lastAccountStatusRefreshAt = now()
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
            lastRepairResult = try await libraryStore.repairSyncDuplicates(modelContext: modelContext)
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

        return now().timeIntervalSince(lastAccountStatusRefreshAt) >= Self.accountStatusRefreshInterval
    }

    private func updateAccountStatus(_ status: SyncAccountStatus) {
        if accountStatus != status {
            accountStatus = status
        }
    }
}
