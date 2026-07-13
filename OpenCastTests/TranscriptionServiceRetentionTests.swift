import Foundation
import OpenCastTranscription
import Synchronization
import Testing
@testable import OpenCast

@Suite("Transcription service retention")
struct TranscriptionServiceRetentionTests {
    final class SpyService: RetainableTranscriptionService {
        private let unloadCount = Mutex<Int>(0)

        var unloads: Int {
            unloadCount.withLock { $0 }
        }

        func unload() async {
            unloadCount.withLock { $0 += 1 }
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

    /// Fire-and-forget unloads run on detached tasks; poll briefly.
    private func waitForUnloads(_ service: SpyService, count: Int) async throws {
        for _ in 0..<200 where service.unloads < count {
            try await Task.sleep(for: .milliseconds(5))
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

        try await waitForUnloads(service, count: 1)
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

        try await waitForUnloads(service, count: 1)
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

        try await waitForUnloads(first, count: 1)
        #expect(retention.checkout(key) === second)
        await retention.endDrain()
    }
}
