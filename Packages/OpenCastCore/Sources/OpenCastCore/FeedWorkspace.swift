import Darwin
import Foundation
import Synchronization

/// Immutable ownership token for one feed artifact directory. Releasing or
/// explicitly discarding it queues deletion on one utility worker, keeping
/// recursive file removal off the actor that releases a prepared feed.
final class FeedWorkspace: Sendable {
    let directory: URL
    private let cleanupScheduled = Mutex(false)

    private static let ownerState = Mutex<FeedWorkspaceProcessOwner?>(nil)
    private static let cleanup = FeedWorkspaceCleanup()

    init() throws {
        let owner = try Self.processOwner()
        directory = owner.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    private static func processOwner() throws -> FeedWorkspaceProcessOwner {
        try ownerState.withLock { owner in
            if let owner {
                return owner
            }
            let created = try FeedWorkspaceProcessOwner()
            owner = created
            return created
        }
    }

    func file(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    func discard() {
        let shouldSchedule = cleanupScheduled.withLock { scheduled in
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if shouldSchedule {
            Self.cleanup.enqueue(directory)
        }
    }

    /// Starts a liveness-checked sweep without waiting on the caller's actor.
    static func cleanAbandonedJobs() {
        cleanup.enqueueAbandonedSweep {
            // First ownership creation can wait for another process's sweep.
            // Resolve it on the cleanup worker, never on the startup actor.
            try processOwner().directory
        }
    }

    /// Test synchronization point: all cleanup queued before this call has
    /// completed when it returns.
    static func waitForCleanup() async {
        await cleanup.waitUntilIdle()
    }

    static var jobsRootForTesting: URL {
        FeedWorkspaceProcessOwner.root
    }

    static func blockNextCleanupForTesting() -> FeedWorkspaceCleanupBarrier {
        cleanup.blockNextRemoval()
    }

    deinit {
        discard()
    }
}

/// One UUID directory per process plus an advisory owner lock distinguishes a
/// live producer from abandoned files. Unlike a PID name, the UUID cannot be
/// mistaken for a later process after PID reuse.
private final class FeedWorkspaceProcessOwner: @unchecked Sendable {
    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("OpenCastFeedJobs", isDirectory: true)
    static let registryLockURL = root.appendingPathComponent(".registry.lock")

    let directory: URL
    private let lockDescriptor: Int32

    init() throws {
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let registry = try Self.openLock(Self.registryLockURL)
        guard flock(registry, LOCK_EX) == 0 else {
            Darwin.close(registry)
            throw CocoaError(.fileLocking)
        }
        defer {
            _ = flock(registry, LOCK_UN)
            Darwin.close(registry)
        }

        let directory = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let descriptor = try Self.openLock(directory.appendingPathComponent(".owner.lock"))
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(descriptor)
                throw CocoaError(.fileLocking)
            }
            self.directory = directory
            lockDescriptor = descriptor
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func openLock(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CocoaError(.fileLocking)
        }
        return descriptor
    }

    deinit {
        _ = flock(lockDescriptor, LOCK_UN)
        Darwin.close(lockDescriptor)
    }
}

/// Coalesces every deletion onto one serial worker. The pending set bounds
/// duplicate requests and a single drain closure handles bursts of artifacts.
private final class FeedWorkspaceCleanup: @unchecked Sendable {
    private struct State {
        var pending: Set<URL> = []
        var drainScheduled = false
        var sweepScheduled = false
        var nextRemovalBarrier: FeedWorkspaceCleanupBarrier?
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "com.connor.opencast.feed-workspace-cleanup", qos: .utility)

    func enqueue(_ url: URL) {
        let shouldSchedule = state.withLock { state in
            state.pending.insert(url)
            guard !state.drainScheduled else { return false }
            state.drainScheduled = true
            return true
        }
        if shouldSchedule {
            queue.async { [self] in drain() }
        }
    }

    func enqueueAbandonedSweep(ownerDirectory: @escaping @Sendable () throws -> URL) {
        let shouldSchedule = state.withLock { state in
            guard !state.sweepScheduled else { return false }
            state.sweepScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        queue.async { [self] in
            defer { state.withLock { $0.sweepScheduled = false } }
            do {
                sweepAbandoned(excluding: try ownerDirectory())
            } catch {
                // A later workspace initializer retries and reports the error.
            }
        }
    }

    func blockNextRemoval() -> FeedWorkspaceCleanupBarrier {
        let barrier = FeedWorkspaceCleanupBarrier()
        state.withLock { state in
            precondition(state.nextRemovalBarrier == nil)
            state.nextRemovalBarrier = barrier
        }
        return barrier
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    private func drain() {
        while true {
            let urls = state.withLock { state -> [URL] in
                guard !state.pending.isEmpty else {
                    state.drainScheduled = false
                    return []
                }
                let urls = Array(state.pending)
                state.pending.removeAll(keepingCapacity: true)
                return urls
            }
            guard !urls.isEmpty else { return }
            let barrier = state.withLock { state in
                defer { state.nextRemovalBarrier = nil }
                return state.nextRemovalBarrier
            }
            barrier?.blockCleanupWorker()
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func sweepAbandoned(excluding activeDirectory: URL) {
        guard let registry = try? FeedWorkspaceProcessOwner.openLock(
            FeedWorkspaceProcessOwner.registryLockURL
        ) else {
            return
        }
        defer { Darwin.close(registry) }
        guard flock(registry, LOCK_EX) == 0 else { return }
        defer {
            _ = flock(registry, LOCK_UN)
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: FeedWorkspaceProcessOwner.root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for directory in children where directory != activeDirectory {
            guard (try? directory.resourceValues(forKeys: keys).isDirectory) == true else {
                continue
            }
            let lockURL = directory.appendingPathComponent(".owner.lock")
            guard let owner = try? FeedWorkspaceProcessOwner.openLock(lockURL) else {
                continue
            }
            let isAbandoned = flock(owner, LOCK_EX | LOCK_NB) == 0
            if isAbandoned {
                try? FileManager.default.removeItem(at: directory)
                _ = flock(owner, LOCK_UN)
            }
            Darwin.close(owner)
        }
    }
}

/// Narrow synchronization seam proving cleanup never executes on the actor
/// that releases a workspace. Only package tests install one.
final class FeedWorkspaceCleanupBarrier: @unchecked Sendable {
    private struct State {
        var reached = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    fileprivate func blockCleanupWorker() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.reached = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
        releaseSemaphore.wait()
    }

    func waitUntilReached() async {
        let shouldWait = state.withLock { !$0.reached }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { state in
                if state.reached { return true }
                state.waiter = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func release() {
        releaseSemaphore.signal()
    }
}
