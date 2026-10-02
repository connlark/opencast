import Foundation
import Observation
import SwiftData

@Observable
final class SyncStatusStore {
    private static let accountStatusRefreshInterval: TimeInterval = 30
    /// How long launch and foreground work waits for an account answer before
    /// carrying on without one. The check is a system round trip that
    /// normally answers in milliseconds and has taken over 30 seconds on a
    /// cold system; nothing the app shows should hang on it for that long.
    static let defaultAccountStatusPatience: Duration = .seconds(10)

    private(set) var accountStatus: SyncAccountStatus = .notChecked
    private(set) var libraryActivity: SyncLibraryActivity = .idle
    private(set) var isRepairingDuplicates = false
    private(set) var lastRepairResult: SyncRepairResult?
    private(set) var lastRepairErrorMessage: String?
    private(set) var isMergingDuplicateEpisodes = false
    private(set) var lastEpisodeMergeResult: EpisodeMergeResult?
    private(set) var lastEpisodeMergeErrorMessage: String?

    @ObservationIgnored private let accountStatusProvider: any CloudKitAccountStatusProviding
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let accountStatusPatience: Duration
    @ObservationIgnored private var accountStatusRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastAccountStatusRefreshAt: Date?

    init(
        accountStatusProvider: any CloudKitAccountStatusProviding = CloudKitAccountStatusProvider(),
        now: @escaping () -> Date = { Date.now },
        accountStatusPatience: Duration = SyncStatusStore.defaultAccountStatusPatience
    ) {
        self.accountStatusProvider = accountStatusProvider
        self.now = now
        self.accountStatusPatience = accountStatusPatience
    }

    /// Refreshes the account status, waiting for the answer only as long as
    /// the store's patience. A check that has not answered by then keeps
    /// running and publishes its status whenever it arrives; the caller gets
    /// the status known so far (`.checking` on a first check) and moves on.
    @discardableResult
    func refreshAccountStatusWithinPatience(force: Bool = false) async -> SyncAccountStatus {
        guard accountStatusRefreshTask != nil || force || shouldRefreshAccountStatus() else {
            return accountStatus
        }

        let refresh = Task { [self] in
            await refreshAccountStatus(force: force)
        }
        let wait = AccountStatusWait()
        let patience = accountStatusPatience
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let timeout = Task {
                try? await Task.sleep(for: patience)
                wait.finish(continuation)
            }
            Task {
                _ = await refresh.value
                timeout.cancel()
                wait.finish(continuation)
            }
        }
        return accountStatus
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

    func beginLibraryActivity(_ activity: SyncLibraryActivity) {
        if libraryActivity != activity {
            libraryActivity = activity
        }
    }

    func finishLibraryActivity() {
        beginLibraryActivity(.idle)
    }

    func recordLibraryActivityFailure(_ message: String) {
        beginLibraryActivity(.failed(message))
    }

    @discardableResult
    func repairDuplicates(modelContext: ModelContext, libraryStore: LibraryStore) async -> SyncRepairResult? {
        guard !isRepairingDuplicates else {
            return lastRepairResult
        }

        isRepairingDuplicates = true
        defer {
            isRepairingDuplicates = false
        }

        await Task.yield()

        do {
            lastRepairResult = try await libraryStore.repairSyncDuplicates(modelContext: modelContext)
            lastRepairErrorMessage = nil
            return lastRepairResult
        } catch {
            lastRepairResult = nil
            lastRepairErrorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func mergeDuplicateEpisodes(modelContext: ModelContext, libraryStore: LibraryStore) async -> EpisodeMergeResult? {
        guard !isMergingDuplicateEpisodes else {
            return lastEpisodeMergeResult
        }

        isMergingDuplicateEpisodes = true
        defer {
            isMergingDuplicateEpisodes = false
        }

        await Task.yield()

        do {
            lastEpisodeMergeResult = try await libraryStore.mergeDuplicateEpisodes(modelContext: modelContext)
            lastEpisodeMergeErrorMessage = nil
            return lastEpisodeMergeResult
        } catch {
            lastEpisodeMergeResult = nil
            lastEpisodeMergeErrorMessage = error.localizedDescription
            return nil
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

/// Resumes a patience-bounded account wait exactly once, whichever of the
/// answer and the timeout comes first.
private final class AccountStatusWait {
    private var isFinished = false

    func finish(_ continuation: CheckedContinuation<Void, Never>) {
        guard !isFinished else {
            return
        }

        isFinished = true
        continuation.resume()
    }
}
