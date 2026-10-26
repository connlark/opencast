import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Analysis trial status cache")
struct AnalysisTrialStatusCacheTests {
    static let start = Date(timeIntervalSince1970: 1_792_929_600) // 2026-10-25T12:00:00Z

    /// A settable clock and a scripted fetch that counts its calls.
    @MainActor
    final class Harness {
        var now = AnalysisTrialStatusCacheTests.start
        var next: AnalysisTrialProxyStatus?
        var fetches = 0
        var published: [AnalysisTrialStatus] = []
        let suiteName = "opencast-trial-status-tests-\(UUID().uuidString)"
        lazy var defaults = UserDefaults(suiteName: suiteName)!

        func cache() -> AnalysisTrialStatusCache {
            let cache = AnalysisTrialStatusCache(
                defaults: defaults,
                now: { [unowned self] in self.now },
                fetch: { [unowned self] in
                    self.fetches += 1
                    return self.next
                }
            )
            cache.onStatus = { [unowned self] in self.published.append($0) }
            return cache
        }

        func remove() {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
    }

    static let units3 = AnalysisTrialProxyStatus(mode: .trial, unitsRemaining: 3, startsAt: start, monthPaused: false)
    static let units2 = AnalysisTrialProxyStatus(mode: .trial, unitsRemaining: 2, startsAt: start, monthPaused: false)
    static let open = AnalysisTrialProxyStatus(mode: .open, unitsRemaining: 5, startsAt: start.addingTimeInterval(86_400), monthPaused: false)

    @Test("A status younger than an hour is served from the cache; an hour old is fetched again")
    func timeToLive() async {
        let harness = Harness()
        defer { harness.remove() }
        let cache = harness.cache()
        harness.next = Self.units3

        #expect(await cache.status(forceRefresh: false) == Self.units3)
        harness.next = Self.units2
        harness.now = Self.start.addingTimeInterval(AnalysisTrialStatusCache.timeToLive - 1)
        #expect(await cache.status(forceRefresh: false) == Self.units3)
        #expect(harness.fetches == 1)

        harness.now = Self.start.addingTimeInterval(AnalysisTrialStatusCache.timeToLive)
        #expect(await cache.status(forceRefresh: false) == Self.units2)
        #expect(harness.fetches == 2)
        #expect(cache.fetchedAt == harness.now)
    }

    @Test("A clock set back before the last fetch fetches again")
    func clockSetBack() async {
        let harness = Harness()
        defer { harness.remove() }
        let cache = harness.cache()
        harness.next = Self.units3
        _ = await cache.status(forceRefresh: false)

        harness.now = Self.start.addingTimeInterval(-60)
        harness.next = Self.units2
        #expect(await cache.status(forceRefresh: false) == Self.units2)
        #expect(harness.fetches == 2)
    }

    @Test("The status persists across launches in the analysis.trialStatus preference")
    func persistsAcrossInstances() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.next = Self.open
        _ = await harness.cache().status(forceRefresh: false)
        #expect(harness.defaults.data(forKey: "analysis.trialStatus") != nil)
        #expect(AnalysisTrialStatusCache.preferenceKey == "analysis.trialStatus")

        let relaunched = harness.cache()
        #expect(relaunched.status == Self.open)
        #expect(relaunched.fetchedAt == Self.start)
        harness.now = Self.start.addingTimeInterval(600)
        #expect(await relaunched.status(forceRefresh: false) == Self.open)
        #expect(harness.fetches == 1)
    }

    @Test("forceRefresh fetches even while the cached status is fresh")
    func forceRefresh() async {
        let harness = Harness()
        defer { harness.remove() }
        let cache = harness.cache()
        harness.next = Self.units3
        _ = await cache.status(forceRefresh: false)

        harness.next = Self.units2
        #expect(await cache.status(forceRefresh: true) == Self.units2)
        #expect(harness.fetches == 2)
        #expect(cache.status == Self.units2)
    }

    @Test("A failed fetch returns nil and keeps nothing new")
    func failedFetch() async {
        let harness = Harness()
        defer { harness.remove() }
        let cache = harness.cache()
        harness.next = nil
        #expect(await cache.status(forceRefresh: false) == nil)
        #expect(cache.status == nil)
        #expect(cache.fetchedAt == nil)
        #expect(harness.defaults.data(forKey: AnalysisTrialStatusCache.preferenceKey) == nil)
        #expect(harness.published.isEmpty)

        harness.next = Self.units3
        _ = await cache.status(forceRefresh: false)
        let stored = harness.defaults.data(forKey: AnalysisTrialStatusCache.preferenceKey)
        harness.next = nil
        harness.now = Self.start.addingTimeInterval(AnalysisTrialStatusCache.timeToLive * 2)
        #expect(await cache.status(forceRefresh: false) == nil)
        #expect(cache.status == Self.units3)
        #expect(cache.fetchedAt == Self.start)
        #expect(harness.defaults.data(forKey: AnalysisTrialStatusCache.preferenceKey) == stored)
        #expect(harness.published == [.unitsLeft(3)])
    }

    @Test("Every fetched status is published as the key notice's trial status")
    func onStatusFires() async {
        let harness = Harness()
        defer { harness.remove() }
        let cache = harness.cache()
        for status in [Self.open, Self.units3, AnalysisTrialProxyStatus(mode: .trial, unitsRemaining: 0, startsAt: Self.start, monthPaused: true)] {
            harness.next = status
            _ = await cache.status(forceRefresh: true)
        }
        // A cache hit publishes nothing.
        _ = await cache.status(forceRefresh: false)
        #expect(harness.published == [.notStarted, .unitsLeft(3), .exhausted])
    }

    /// Holds a fetch until opened.
    @MainActor
    final class FetchGate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    @Test("Concurrent callers share one fetch")
    func concurrentCallersShareOneFetch() async {
        let harness = Harness()
        defer { harness.remove() }
        let gate = FetchGate()
        let cache = AnalysisTrialStatusCache(
            defaults: harness.defaults,
            now: { AnalysisTrialStatusCacheTests.start },
            fetch: {
                harness.fetches += 1
                await gate.wait()
                return AnalysisTrialStatusCacheTests.units3
            }
        )

        async let first = cache.status(forceRefresh: true)
        async let second = cache.status(forceRefresh: true)
        async let third = cache.status(forceRefresh: false)
        // Let all three reach the fetch before it answers.
        for _ in 0..<100 { await Task.yield() }
        gate.open()
        let results = await [first, second, third]

        #expect(results == [Self.units3, Self.units3, Self.units3])
        #expect(harness.fetches == 1)
    }

    @Test("reset forgets the status here and in the preference")
    func reset() async {
        let harness = Harness()
        defer { harness.remove() }
        let cache = harness.cache()
        harness.next = Self.units3
        _ = await cache.status(forceRefresh: false)

        cache.reset()

        #expect(cache.status == nil)
        #expect(cache.fetchedAt == nil)
        #expect(harness.defaults.data(forKey: AnalysisTrialStatusCache.preferenceKey) == nil)
        #expect(harness.cache().status == nil)
        _ = await cache.status(forceRefresh: false)
        #expect(harness.fetches == 2)
    }

    @Test("A status body decodes from the service's JSON; a negative count or a missing field does not")
    func decoding() {
        let body = #"{"mode":"trial","units_remaining":4,"starts_at":"2027-01-01T00:00:00Z","month_paused":false}"#
        let status = AnalysisTrialProxyStatus.decode(Data(body.utf8))
        #expect(status?.mode == .trial)
        #expect(status?.unitsRemaining == 4)
        #expect(status?.trialStatus == .unitsLeft(4))
        #expect(AnalysisTrialProxyStatus.decode(Data(#"{"mode":"open","units_remaining":5,"starts_at":"2027-01-01T00:00:00Z","month_paused":false}"#.utf8))?.trialStatus == .notStarted)
        #expect(AnalysisTrialProxyStatus.decode(Data(#"{"mode":"trial","units_remaining":-1,"starts_at":"2027-01-01T00:00:00Z","month_paused":false}"#.utf8)) == nil)
        #expect(AnalysisTrialProxyStatus.decode(Data(#"{"mode":"trial","units_remaining":1}"#.utf8)) == nil)
        #expect(AnalysisTrialProxyStatus.decode(Data(#"{"error":"trial_unavailable"}"#.utf8)) == nil)
    }
}
