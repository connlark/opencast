import Foundation
import OpenCastTranscription
import UIKit

/// The retention seam: anything unloadable the drain can hold onto.
protocol RetainableTranscriptionService: AnyObject, Sendable {
    func unload() async
}

extension OpenCastTranscriptionService: RetainableTranscriptionService {}

/// Bounded retention of a loaded transcription service across items within
/// one active ad-free-pass queue drain (whisper-perf E1), so items 2..n skip
/// the ~4.4 s model load. Retention is scoped strictly to a drain: begin/end
/// come from the queue coordinator, and anything outside a drain unloads per
/// item exactly as before — there is never an idle resident model.
///
/// The retained service is dropped on: drain end, key mismatch (model or
/// compute-profile change), any run failure or cancellation (a drain never
/// reuses a runtime after a failed attempt), explicit hard unload, and
/// memory-pressure warnings.
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

    /// Hands the retained service to the caller when a drain is active and
    /// the identity matches; ownership transfers out (a successful run
    /// re-retains, a failed run unloads through the normal path).
    func checkout(_ key: Key) -> (any RetainableTranscriptionService)? {
        lock.withLock {
            guard drainActive, let current = retained, current.key == key else {
                return nil
            }
            retained = nil
            return current.service
        }
    }

    /// Retains after a successful run. Returns false when no drain is active
    /// — the caller unloads per item as before.
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
