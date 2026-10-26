import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Security
import Synchronization
import Testing
@testable import OpenCast

@MainActor
@Suite("Analysis route resolver")
struct AnalysisRouteResolverTests {
    nonisolated static let googleKey = AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText)
    nonisolated static let openAIKey = AnalysisKeyFixtures.key(AnalysisKeyFixtures.openAIText)
    nonisolated static let open = AnalysisTrialProxyStatus(mode: .open, unitsRemaining: 5, startsAt: .distantFuture, monthPaused: false)

    nonisolated static func trial(units: Int, paused: Bool = false) -> AnalysisTrialProxyStatus {
        AnalysisTrialProxyStatus(mode: .trial, unitsRemaining: units, startsAt: .distantPast, monthPaused: paused)
    }

    /// Fails every Keychain read while set.
    nonisolated final class ReadFailure: Sendable {
        private let failing = Mutex(false)

        var isFailing: Bool {
            get { failing.withLock { $0 } }
            set { failing.withLock { $0 = newValue } }
        }

        var fault: InMemoryAnalysisProviderKeyStorage.Fault {
            { [self] operation, _ in operation == .read && isFailing ? errSecInteractionNotAllowed : nil }
        }
    }

    /// One resolver over in-memory keys, a fixed bundle, a scripted trial
    /// status and a run directory of its own.
    @MainActor
    final class Stack {
        let storage: InMemoryAnalysisProviderKeyStorage
        let keys: AnalysisProviderKeyStore
        let runs: AnalysisRunRecordStore
        let connection: FixedTrialConnection
        let exchange = RecordingTrialProxyExchange()
        let statusFetches = AnalysisTestCounter()
        let snapshot: AnalysisPolicySnapshot
        let resolver: AnalysisRouteResolver
        private let suiteName = "opencast-route-resolver-tests-\(UUID().uuidString)"

        init(
            snapshot: AnalysisPolicySnapshot = .baked,
            keys seeded: [AnalysisProvider: AnalysisProviderKey] = [:],
            readFailure: ReadFailure? = nil,
            effective: AnalysisProvider? = .google,
            status: AnalysisTrialProxyStatus? = AnalysisRouteResolverTests.open,
            hasTrialRoute: Bool = true,
            duringStatusFetch: @escaping @Sendable () -> Void = {}
        ) {
            self.snapshot = snapshot
            storage = InMemoryAnalysisProviderKeyStorage(
                seeded: seeded.mapValues { ($0, syncs: false) },
                fault: readFailure?.fault
            )
            keys = AnalysisProviderKeyStore(storage: storage)
            runs = AnalysisRunRecordStore(directory: AnalysisRunTestFixtures.temporaryDirectory())
            connection = FixedTrialConnection(exchange: hasTrialRoute ? exchange : nil, isConfigured: hasTrialRoute)
            let fetches = statusFetches
            resolver = AnalysisRouteResolver(
                keys: keys,
                policy: .fixed(snapshot),
                storedProvider: { _ in effective },
                trialStatus: AnalysisTrialStatusCache(defaults: UserDefaults(suiteName: suiteName)!, fetch: {
                    fetches.add()
                    duringStatusFetch()
                    return status
                }),
                trial: connection,
                runs: runs
            )
        }

        deinit {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: runs.directory)
        }

        func resolve(_ feature: AnalysisFeature, resuming runID: String? = nil) async -> AnalysisRouteResolution {
            await resolver.resolve(feature: feature, resumingRunID: runID)
        }

        func trialPolicy(_ feature: AnalysisFeature) -> AnalysisRoutePolicy {
            AnalysisRouteResolver.trialPolicy(feature: feature, snapshot: snapshot)!
        }

        func directPolicy(_ feature: AnalysisFeature, _ provider: AnalysisProvider) -> AnalysisRoutePolicy {
            AnalysisRouteResolver.directPolicy(feature: feature, provider: provider, snapshot: snapshot)!
        }

        /// Writes a run record as `begin` would before its first send.
        func beginRun(_ feature: AnalysisFeature, route: AnalysisRoute, policy: AnalysisRoutePolicy) throws -> String {
            let id = UUID().uuidString
            try runs.begin(AnalysisRunRecord(
                id: id,
                feature: feature,
                episodeID: "episode-1",
                podcastID: "podcast-1",
                transcriptFingerprint: "fixture-fingerprint",
                resolution: AnalysisRouteResolution(feature: feature, route: route, policy: policy, key: nil, resumingRunID: nil, trialExchange: nil),
                policy: policy
            ))
            return id
        }
    }

    static func keyBytes(_ resolution: AnalysisRouteResolution) -> Data? {
        AnalysisKeyFixtures.bytes(of: resolution.key)
    }

    // MARK: New runs

    @Test("A saved key routes direct with the bundle's entry, its in-flight limit and the key", arguments: [AnalysisFeature.adDetection, .chaptersSummary], [AnalysisProvider.google, .openai])
    func savedKeyRoutesDirect(feature: AnalysisFeature, provider: AnalysisProvider) async {
        let key = provider == .google ? Self.googleKey : Self.openAIKey
        let stack = Stack(keys: [provider: key], effective: provider)

        let resolution = await stack.resolve(feature)

        #expect(resolution.route == .direct(provider: provider))
        #expect(resolution.provider == provider)
        #expect(resolution.policy == stack.directPolicy(feature, provider))
        #expect(Self.keyBytes(resolution) == AnalysisKeyFixtures.bytes(of: key))
        #expect(resolution.resumingRunID == nil)
        #expect(resolution.trialExchange == nil)
        if feature == .adDetection {
            #expect(resolution.policy?.adDetection?.settings.window.maxInFlight == AnalysisPolicyBundle.baked.features.adDetection.window.maxInFlight)
        }
        #expect(stack.connection.exchangeCalls == 0)
        #expect(stack.statusFetches.count == 0)
    }

    @Test("A Keychain read that fails is keychainUnreadable, never the trial", arguments: [AnalysisFeature.adDetection, .chaptersSummary])
    func unreadableKeychain(feature: AnalysisFeature) async {
        let failure = ReadFailure()
        failure.isFailing = true
        let stack = Stack(keys: [.google: Self.googleKey], readFailure: failure, status: Self.open)

        let resolution = await stack.resolve(feature)

        #expect(resolution.route == .keyRequired(.keychainUnreadable))
        #expect(resolution.keyRequiredReason == .keychainUnreadable)
        #expect(resolution.policy == nil)
        #expect(resolution.key == nil)
        #expect(stack.connection.exchangeCalls == 0)
        #expect(stack.statusFetches.count == 0)
    }

    @Test("A provider whose presence could not be read is tried, and routes direct when it holds a key", arguments: [AnalysisProvider?.some(.google), nil])
    func unreadProviderHoldingAKey(effective: AnalysisProvider?) async {
        let failure = ReadFailure()
        let stack = Stack(readFailure: failure, effective: effective)
        failure.isFailing = true
        await stack.keys.refreshPresences()
        failure.isFailing = false
        #expect(stack.keys.lastReadFailed(.openai))
        stack.storage.place(Data(AnalysisKeyFixtures.openAIText.utf8), provider: .openai, synchronizable: false)

        let resolution = await stack.resolve(.adDetection)

        #expect(resolution.route == .direct(provider: .openai))
        #expect(Self.keyBytes(resolution) == Data(AnalysisKeyFixtures.openAIText.utf8))
        #expect(stack.statusFetches.count == 0)
    }

    @Test("A key the presence cache has not read yet still routes direct, never the trial")
    func keyBeforePresenceRead() async {
        // The presence cache starts empty: before the first refresh no
        // provider is effective, yet the Keychain already holds a key.
        let stack = Stack(keys: [.google: Self.googleKey], effective: nil)

        let resolution = await stack.resolve(.adDetection)

        #expect(resolution.route == .direct(provider: .google))
        #expect(Self.keyBytes(resolution) == Data(AnalysisKeyFixtures.googleText.utf8))
        #expect(stack.statusFetches.count == 0)
    }

    @Test("Before any presence read, the stored choice picks among the keys the Keychain holds; else Google, else the only one")
    func storedChoiceOverFreshKeys() async {
        let both: [AnalysisProvider: AnalysisProviderKey] = [.google: Self.googleKey, .openai: Self.openAIKey]
        #expect(await Stack(keys: both, effective: .openai).resolve(.adDetection).route == .direct(provider: .openai))
        #expect(await Stack(keys: both, effective: nil).resolve(.adDetection).route == .direct(provider: .google))
        #expect(await Stack(keys: [.openai: Self.openAIKey], effective: .google).resolve(.adDetection).route == .direct(provider: .openai))
    }

    @Test("A key saved while the trial status is read wins over the trial's answer, a used-up trial included", arguments: [
        AnalysisRouteResolverTests.trial(units: 0), AnalysisRouteResolverTests.trial(units: 2, paused: true), AnalysisRouteResolverTests.open,
    ])
    func keySavedDuringStatusFetch(status: AnalysisTrialProxyStatus) async {
        let hook = StatusFetchHook()
        let stack = Stack(effective: nil, status: status, duringStatusFetch: { hook.run() })
        let storage = stack.storage
        hook.set { storage.place(Data(AnalysisKeyFixtures.googleText.utf8), provider: .google, synchronizable: false) }

        let resolution = await stack.resolve(.adDetection)

        #expect(resolution.route == .direct(provider: .google))
        #expect(stack.statusFetches.count == 1)
    }

    @Test("A saved key whose provider has no entry for the feature is skipped")
    func keyWithoutAnEntryIsSkipped() async {
        let snapshot = AnalysisUITestFixtures.policySnapshot(variant: "no-openai-chapters")
        let stack = Stack(snapshot: snapshot, keys: [.openai: Self.openAIKey], effective: .openai)

        #expect(await stack.resolve(.chaptersSummary).route == .trial)
        #expect(await stack.resolve(.adDetection).route == .direct(provider: .openai))
    }

    @Test("Without a key, an open trial routes to the trial, ad detection one window at a time", arguments: [AnalysisFeature.adDetection, .chaptersSummary])
    func openTrial(feature: AnalysisFeature) async throws {
        let stack = Stack(status: Self.open)

        let resolution = await stack.resolve(feature)

        #expect(resolution.route == .trial)
        #expect(resolution.provider == .google)
        #expect(resolution.key == nil)
        #expect(resolution.trialExchange != nil)
        #expect(resolution.resumingRunID == nil)
        let policy = try #require(resolution.policy)
        #expect(policy.model.provider == .google)
        #expect(policy.model.modelID == stack.snapshot.bundle.trial.modelID)
        switch feature {
        case .adDetection:
            var expected = try #require(stack.snapshot.trialAdDetection).settings
            expected.window.maxInFlight = 1
            #expect(policy.adDetection?.settings == expected)
        case .chaptersSummary:
            let entry = try #require(stack.snapshot.chaptersSummary(provider: .google))
            #expect(policy == .chaptersSummary(entry))
        }
        #expect(stack.statusFetches.count == 1)
    }

    @Test("The trial status decides the route", arguments: [AnalysisFeature.adDetection, .chaptersSummary], [
        (AnalysisRouteResolverTests.trial(units: 3), AnalysisRoute.trial),
        (AnalysisRouteResolverTests.trial(units: 1), .trial),
        (AnalysisRouteResolverTests.trial(units: 0), .keyRequired(.trialExhausted)),
        (AnalysisRouteResolverTests.trial(units: 3, paused: true), .keyRequired(.trialPaused)),
        (AnalysisRouteResolverTests.trial(units: 0, paused: true), .keyRequired(.trialPaused)),
        (AnalysisTrialProxyStatus(mode: .open, unitsRemaining: 0, startsAt: .distantFuture, monthPaused: true), .trial),
    ])
    func statusDecides(feature: AnalysisFeature, scenario: (status: AnalysisTrialProxyStatus, route: AnalysisRoute)) async {
        let stack = Stack(status: scenario.status)

        let resolution = await stack.resolve(feature)

        #expect(resolution.route == scenario.route)
        #expect((resolution.trialExchange != nil) == (scenario.route == .trial))
    }

    @Test("A trial status that cannot be read is proxyUnavailable")
    func unreadableStatus() async {
        let stack = Stack(status: nil)

        let resolution = await stack.resolve(.adDetection)

        #expect(resolution.route == .keyRequired(.proxyUnavailable))
        #expect(stack.statusFetches.count == 1)
    }

    @Test("No trial route for the build, or no way to sign, is proxyUnavailable before any status read", arguments: [AnalysisFeature.adDetection, .chaptersSummary])
    func noTrialRoute(feature: AnalysisFeature) async {
        let stack = Stack(status: Self.open, hasTrialRoute: false)

        let resolution = await stack.resolve(feature)

        #expect(resolution.route == .keyRequired(.proxyUnavailable))
        #expect(!stack.resolver.isTrialRouteConfigured)
        #expect(stack.connection.exchangeCalls == 1)
        #expect(stack.statusFetches.count == 0)
        #expect(Stack().resolver.isTrialRouteConfigured)
    }

    @Test("A bundle without the trial's model entry is proxyUnavailable for both features")
    func noTrialEntry() async {
        var bundle = AnalysisPolicyBundle.baked
        bundle.trial.modelID = "gemini-unlisted"
        let stack = Stack(snapshot: AnalysisPolicySnapshot(bundle: bundle, source: .baked, fallbackReason: nil, lastRefreshFailure: nil))

        #expect(await stack.resolve(.adDetection).route == .keyRequired(.proxyUnavailable))
        #expect(await stack.resolve(.chaptersSummary).route == .keyRequired(.proxyUnavailable))
        #expect(stack.connection.exchangeCalls == 0)
        #expect(stack.statusFetches.count == 0)
    }

    // MARK: Resumed runs

    @Test("A trial run resumes under its id with no units left and no status read", arguments: [AnalysisFeature.adDetection, .chaptersSummary], [false, true])
    func trialResumeNeedsNoUnit(feature: AnalysisFeature, expired: Bool) async throws {
        let stack = Stack(status: Self.trial(units: 0))
        let runID = try stack.beginRun(feature, route: .trial, policy: stack.trialPolicy(feature))
        if expired { stack.runs.markExpired(runID: runID) }

        let resolution = await stack.resolve(feature, resuming: runID)

        #expect(resolution.route == .trial)
        #expect(resolution.resumingRunID == runID)
        #expect(resolution.policy == stack.trialPolicy(feature))
        #expect(resolution.trialExchange != nil)
        #expect(stack.statusFetches.count == 0)
    }

    @Test("A trial resume without a trial route is proxyUnavailable")
    func trialResumeWithoutRoute() async throws {
        let stack = Stack(hasTrialRoute: false)
        let runID = try stack.beginRun(.adDetection, route: .trial, policy: stack.trialPolicy(.adDetection))

        let resolution = await stack.resolve(.adDetection, resuming: runID)

        #expect(resolution.route == .keyRequired(.proxyUnavailable))
        #expect(resolution.resumingRunID == nil)
    }

    @Test("A resume under another revision, model or bundle version resolves as a new run", arguments: ["revision", "model", "bundle"])
    func policyChangeStartsANewRun(change: String) async throws {
        let stack = Stack(keys: [.google: Self.googleKey], status: Self.trial(units: 0))
        func changed(_ policy: AnalysisRoutePolicy) -> AnalysisRoutePolicy {
            let ad = policy.adDetection!
            switch change {
            case "revision":
                var settings = ad.settings
                settings.revision = "2026-01-01.0-older"
                return .adDetection(ad.with(settings: settings))
            case "model":
                var model = ad.model
                model.modelID = "gemini-3.7-flash"
                return .adDetection(ad.with(model: model))
            default:
                return .adDetection(AnalysisPolicy(bundleVersion: ad.bundleVersion - 1, source: ad.source, settings: ad.settings, model: ad.model))
            }
        }

        // The trial run: the new run finds the key, so it goes direct.
        let trialRun = try stack.beginRun(.adDetection, route: .trial, policy: changed(stack.trialPolicy(.adDetection)))
        let trialResolution = await stack.resolve(.adDetection, resuming: trialRun)
        #expect(trialResolution.resumingRunID == nil)
        #expect(trialResolution.route == .direct(provider: .google))

        // The direct run: a new run on the same key.
        let directRun = try stack.beginRun(.adDetection, route: .direct(provider: .google), policy: changed(stack.directPolicy(.adDetection, .google)))
        let directResolution = await stack.resolve(.adDetection, resuming: directRun)
        #expect(directResolution.resumingRunID == nil)
        #expect(directResolution.route == .direct(provider: .google))
        #expect(directResolution.policy == stack.directPolicy(.adDetection, .google))

        // Without the key, the new run meets the empty trial.
        let keyless = Stack(status: Self.trial(units: 0))
        let keylessRun = try keyless.beginRun(.adDetection, route: .trial, policy: changed(keyless.trialPolicy(.adDetection)))
        let keylessResolution = await keyless.resolve(.adDetection, resuming: keylessRun)
        #expect(keylessResolution.resumingRunID == nil)
        #expect(keylessResolution.route == .keyRequired(.trialExhausted))
    }

    @Test("A direct run resumes on its own provider while that key reads, whichever provider is selected")
    func directResume() async throws {
        let stack = Stack(keys: [.google: Self.googleKey, .openai: Self.openAIKey], effective: .google)
        let runID = try stack.beginRun(.adDetection, route: .direct(provider: .openai), policy: stack.directPolicy(.adDetection, .openai))

        let resolution = await stack.resolve(.adDetection, resuming: runID)

        #expect(resolution.route == .direct(provider: .openai))
        #expect(resolution.resumingRunID == runID)
        #expect(Self.keyBytes(resolution) == AnalysisKeyFixtures.bytes(of: Self.openAIKey))
    }

    @Test("A direct run whose key is gone is not resumed")
    func directResumeKeyGone() async throws {
        let stack = Stack(keys: [.google: Self.googleKey], effective: .google, status: Self.trial(units: 0))
        let runID = try stack.beginRun(.adDetection, route: .direct(provider: .openai), policy: stack.directPolicy(.adDetection, .openai))

        let resolution = await stack.resolve(.adDetection, resuming: runID)

        #expect(resolution.resumingRunID == nil)
        #expect(resolution.route == .direct(provider: .google))

        let keyless = Stack(status: Self.trial(units: 0))
        let keylessRun = try keyless.beginRun(.adDetection, route: .direct(provider: .google), policy: keyless.directPolicy(.adDetection, .google))
        let keylessResolution = await keyless.resolve(.adDetection, resuming: keylessRun)
        #expect(keylessResolution.resumingRunID == nil)
        #expect(keylessResolution.route == .keyRequired(.trialExhausted))
    }

    @Test("A direct resume whose key cannot be read is keychainUnreadable")
    func directResumeUnreadable() async throws {
        let failure = ReadFailure()
        let stack = Stack(keys: [.google: Self.googleKey], readFailure: failure)
        let runID = try stack.beginRun(.adDetection, route: .direct(provider: .google), policy: stack.directPolicy(.adDetection, .google))
        failure.isFailing = true

        let resolution = await stack.resolve(.adDetection, resuming: runID)

        #expect(resolution.route == .keyRequired(.keychainUnreadable))
        #expect(resolution.resumingRunID == nil)
    }

    @Test("A run that ended, a run of the other feature and an unknown id resolve as new runs")
    func closedRunsAreNotResumed() async throws {
        let stack = Stack(status: Self.trial(units: 2))
        let finished = try stack.beginRun(.adDetection, route: .trial, policy: stack.trialPolicy(.adDetection))
        stack.runs.finish(runID: finished, outcome: await AnalysisRunTestFixtures.successfulOutcome(), listenerFailure: nil, background: nil)
        let failed = try stack.beginRun(.adDetection, route: .trial, policy: stack.trialPolicy(.adDetection))
        stack.runs.finish(
            runID: failed,
            outcome: .failed(AnalysisFailure(feature: .adDetection, code: .timeout, status: 503)),
            listenerFailure: .timeout,
            background: nil
        )
        let cancelled = try stack.beginRun(.adDetection, route: .trial, policy: stack.trialPolicy(.adDetection))
        stack.runs.markCancelled(runID: cancelled)
        let chapters = try stack.beginRun(.chaptersSummary, route: .trial, policy: stack.trialPolicy(.chaptersSummary))

        for runID in [finished, failed, cancelled, chapters, "unknown-run"] {
            let resolution = await stack.resolve(.adDetection, resuming: runID)
            #expect(resolution.resumingRunID == nil, "\(runID)")
            #expect(resolution.route == .trial)
        }
        #expect(stack.statusFetches.count == 1)
    }
}

/// Runs an action set after the stack exists, from inside its status fetch.
private final class StatusFetchHook: Sendable {
    private let action = Mutex<(@Sendable () -> Void)?>(nil)

    func set(_ run: @escaping @Sendable () -> Void) {
        action.withLock { $0 = run }
    }

    func run() {
        action.withLock { $0 }?()
    }
}
