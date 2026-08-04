import Foundation
import OpenCastTranscription
import Synchronization
import Testing
@testable import OpenCast

@Suite("Transcription service retention")
struct TranscriptionServiceRetentionTests {
    final class SpyService: RetainableTranscriptionService {
        private struct State {
            var unloads = 0
            var waiters: [UUID: (threshold: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
        }

        private let state = Mutex(State())

        var unloads: Int {
            state.withLock { $0.unloads }
        }

        func unload() async {
            let resumable: [CheckedContinuation<Void, Never>] = state.withLock { state in
                state.unloads += 1
                let reached = state.unloads
                let ready = state.waiters.filter { $0.value.threshold <= reached }
                for id in ready.keys {
                    state.waiters.removeValue(forKey: id)
                }
                return ready.values.map(\.continuation)
            }
            for continuation in resumable {
                continuation.resume()
            }
        }

        /// Suspends until `unload()` has run `count` times — each unload
        /// signals arrival directly, so there is no polling budget to race.
        func unloadsReached(_ count: Int) async {
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let alreadyReached = state.withLock { state in
                        if state.unloads >= count || Task.isCancelled {
                            return true
                        }
                        state.waiters[waiterID] = (count, continuation)
                        return false
                    }
                    if alreadyReached {
                        continuation.resume()
                    }
                }
            } onCancel: {
                let displaced = state.withLock { $0.waiters.removeValue(forKey: waiterID) }
                displaced?.continuation.resume()
            }
        }
    }

    private func makeKey(
        profile: OpenCastTranscriptionComputeProfile = .backgroundSafe,
        model: String = "openai_whisper-tiny.en"
    ) -> TranscriptionServiceRetention.Key {
        TranscriptionServiceRetention.Key(
            modelIdentifier: model,
            modelVersion: "20260701_75MB-v1",
            modelTreeSHA256: "60d71f9a",
            computeProfile: profile
        )
    }

    /// Fire-and-forget unloads run on detached tasks; await the spy's own
    /// signal. The generous backstop only trips on a real regression (a test
    /// failure instead of a suite hang), never on load.
    private func waitForUnloads(_ service: SpyService, count: Int) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await service.unloadsReached(count) }
            group.addTask { try? await Task.sleep(for: .seconds(10)) }
            await group.next()
            group.cancelAll()
        }
        #expect(service.unloads == count)
    }

    @Test("No retention outside a drain")
    func noRetentionOutsideDrain() async throws {
        let retention = TranscriptionServiceRetention(memoryWarningName: nil)
        let service = SpyService()
        let key = makeKey()

        #expect(retention.retain(service, key: key) == false)
        #expect(retention.checkout(key) == nil)
    }

    @Test("Checkout returns the retained service once, on exact key match")
    func checkoutTransfersOwnership() async throws {
        let retention = TranscriptionServiceRetention(memoryWarningName: nil)
        let service = SpyService()
        let key = makeKey()

        retention.beginDrain()
        #expect(retention.retain(service, key: key))

        let reused = retention.checkout(key)
        #expect(reused === service)
        // Ownership transferred: nothing left to check out.
        #expect(retention.checkout(key) == nil)
        #expect(service.unloads == 0)
    }

    @Test("Compute-profile change misses the retained runtime")
    func profileChangeMisses() async throws {
        let retention = TranscriptionServiceRetention(memoryWarningName: nil)
        let service = SpyService()

        retention.beginDrain()
        #expect(retention.retain(service, key: makeKey(profile: .backgroundSafe)))
        // The cpuOnly recovery rung must never see the retained runtime.
        #expect(retention.checkout(makeKey(profile: .cpuOnly)) == nil)
        // The original key still hits.
        #expect(retention.checkout(makeKey(profile: .backgroundSafe)) === service)
    }

    @Test("Model change misses the retained runtime")
    func modelChangeMisses() async throws {
        let retention = TranscriptionServiceRetention(memoryWarningName: nil)
        let service = SpyService()

        retention.beginDrain()
        #expect(retention.retain(service, key: makeKey(model: "openai_whisper-tiny.en")))
        #expect(retention.checkout(makeKey(model: "openai_whisper-large-v3")) == nil)
    }

    @Test("Drain end unloads the retained runtime")
    func drainEndUnloads() async throws {
        let retention = TranscriptionServiceRetention(memoryWarningName: nil)
        let service = SpyService()
        let key = makeKey()

        retention.beginDrain()
        #expect(retention.retain(service, key: key))
        await retention.endDrain()

        #expect(service.unloads == 1)
        // Retention window closed: nothing retained, nothing retainable.
        #expect(retention.checkout(key) == nil)
        #expect(retention.retain(service, key: key) == false)
    }

    @Test("Invalidation unloads the retained runtime")
    func invalidateUnloads() async throws {
        let retention = TranscriptionServiceRetention(memoryWarningName: nil)
        let service = SpyService()
        let key = makeKey()

        retention.beginDrain()
        #expect(retention.retain(service, key: key))
        retention.invalidate(reason: "run-failed")

        await waitForUnloads(service, count: 1)
        #expect(retention.checkout(key) == nil)
        // The drain stays open: the next item may retain a fresh runtime.
        let replacement = SpyService()
        #expect(retention.retain(replacement, key: key))
        await retention.endDrain()
    }

    @Test("Memory warning unloads the retained runtime")
    func memoryWarningUnloads() async throws {
        let warningName = Notification.Name("test.transcription.memory-warning")
        let retention = TranscriptionServiceRetention(memoryWarningName: warningName)
        let service = SpyService()
        let key = makeKey()

        retention.beginDrain()
        #expect(retention.retain(service, key: key))

        NotificationCenter.default.post(name: warningName, object: nil)

        await waitForUnloads(service, count: 1)
        #expect(retention.checkout(key) == nil)
        await retention.endDrain()
    }

    @Test("Retaining over a displaced service unloads the displaced one")
    func displacedServiceUnloads() async throws {
        let retention = TranscriptionServiceRetention(memoryWarningName: nil)
        let first = SpyService()
        let second = SpyService()
        let key = makeKey()

        retention.beginDrain()
        #expect(retention.retain(first, key: key))
        #expect(retention.retain(second, key: key))

        await waitForUnloads(first, count: 1)
        #expect(retention.checkout(key) === second)
        await retention.endDrain()
    }
}
