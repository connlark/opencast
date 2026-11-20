import Foundation
import OpenCastTranscription
import UIKit

protocol RetainableTranscriptionService: AnyObject, Sendable {
    func unload() async
}

extension OpenCastTranscriptionService: RetainableTranscriptionService {}

/// Keeps the loaded service between items of one ad-free-pass queue drain, so later items skip
/// the ~4.4 s model load. Outside a drain nothing is retained, so no model ever sits idle.
nonisolated final class TranscriptionServiceRetention: @unchecked Sendable {
    struct Key: Equatable, Sendable {
        var modelIdentifier: String
        var modelVersion: String
        var modelTreeSHA256: String
        var computeProfile: OpenCastTranscriptionComputeProfile
    }

    private struct Retained {
        var key: Key
        var service: any RetainableTranscriptionService
    }

    private let lock = NSLock()
    private var drainActive = false
    private var retained: Retained?
    // Set once in init, removed only in deinit — never mutated concurrently.
    private nonisolated(unsafe) var memoryWarningObserver: (any NSObjectProtocol)?

    init(memoryWarningName: Notification.Name? = UIApplication.didReceiveMemoryWarningNotification) {
        if let memoryWarningName {
            memoryWarningObserver = NotificationCenter.default.addObserver(
                forName: memoryWarningName,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.invalidate(reason: "memory-warning")
            }
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    func beginDrain() {
        lock.withLock { drainActive = true }
    }

    func endDrain() async {
        let dropped: Retained? = lock.withLock {
            drainActive = false
            defer { retained = nil }
            return retained
        }
        guard let dropped else {
            return
        }
        await dropped.service.unload()
        Task { @MainActor in
            AdFreePassBackgroundRunLog.record("retained runtime unloaded reason=drain-ended")
        }
    }

    /// Ownership transfers to the caller: a successful run re-retains, a failed one unloads.
    func checkout(_ key: Key) -> (any RetainableTranscriptionService)? {
        lock.withLock {
            guard drainActive, let current = retained, current.key == key else {
                return nil
            }
            retained = nil
            return current.service
        }
    }

    /// Returns false outside a drain, and the caller then unloads the service itself.
    func retain(_ service: any RetainableTranscriptionService, key: Key) -> Bool {
        var displaced: Retained?
        let didRetain: Bool = lock.withLock {
            guard drainActive else {
                return false
            }
            displaced = retained
            retained = Retained(key: key, service: service)
            return true
        }
        if let displaced {
            Task { await displaced.service.unload() }
        }
        return didRetain
    }

    func invalidate(reason: String) {
        let dropped: Retained? = lock.withLock {
            defer { retained = nil }
            return retained
        }
        guard let dropped else {
            return
        }
        Task { @MainActor in
            AdFreePassBackgroundRunLog.record("retained runtime unloaded reason=\(reason)")
        }
        Task { await dropped.service.unload() }
    }
}
