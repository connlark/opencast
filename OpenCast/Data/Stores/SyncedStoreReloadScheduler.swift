import Foundation

final class SyncedStoreReloadScheduler {
    private let debounce: Duration
    private var task: Task<Void, Never>?
    private var hasPendingReload = false

    init(debounce: Duration = .milliseconds(750)) {
        self.debounce = debounce
    }

    deinit {
        task?.cancel()
    }

    func schedule(_ reload: @escaping @MainActor () async -> Void) {
        hasPendingReload = true
        guard task == nil else { return }

        task = Task {
            defer { task = nil }
            while hasPendingReload {
                do {
                    try await Task.sleep(for: debounce)
                } catch {
                    return
                }
                hasPendingReload = false
                // New CloudKit batches queue another pass; they must not cancel
                // feed requests already hydrating this batch's local cache.
                await reload()
                guard !Task.isCancelled else { return }
            }
        }
    }

    func waitUntilIdle() async {
        await task?.value
    }
}
