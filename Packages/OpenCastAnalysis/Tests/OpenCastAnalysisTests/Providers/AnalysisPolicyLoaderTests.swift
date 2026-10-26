import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
import Testing

@Suite("Analysis policy loader")
struct AnalysisPolicyLoaderTests {
    /// The fixtures sign the baked bundle one and two versions up.
    private static let goodVersion = BakedAnalysisPolicy.bundleVersion + 1
    private static let nextVersion = BakedAnalysisPolicy.bundleVersion + 2

    private let directory = PolicyTestSupport.temporaryDirectory()
    private let clock = TestClock()

    private func loader(
        _ fetcher: ScriptedPolicyFetcher,
        appBuild: Int = PolicyTestSupport.appBuild,
        verifier: AnalysisPolicySignatureVerifier = PolicyTestSupport.testVerifier
    ) -> AnalysisPolicyLoader {
        let clock = clock
        return AnalysisPolicyLoader(
            appBuild: appBuild,
            directory: directory,
            endpoint: AnalysisPolicyEndpoint(baseURL: URL(string: "https://gateway.test")!),
            fetcher: fetcher,
            verifier: verifier,
            now: { clock.now() }
        )
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("Before any refresh the baked copy is active with no reason")
    func bakedBeforeRefresh() async {
        defer { cleanUp() }
        let snapshot = await loader(ScriptedPolicyFetcher(.offline)).snapshot()
        #expect(snapshot.source == .baked)
        #expect(snapshot.bundle == .baked)
        #expect(snapshot.fallbackReason == nil)
    }

    @Test("A verified newer bundle becomes active and survives a relaunch offline")
    func acceptsAndPersistsNewerBundle() async throws {
        defer { cleanUp() }
        let fetcher = ScriptedPolicyFetcher(AnalysisPolicyTestFixtures.good)
        let snapshot = await loader(fetcher).refresh()
        #expect(snapshot.bundle.bundleVersion == Self.goodVersion)
        #expect(snapshot.source == .downloaded(confirmedAt: clock.now()))
        #expect(snapshot.fallbackReason == nil)
        #expect(snapshot.lastRefreshFailure == nil)

        clock.advance(by: 60)
        let relaunched = await loader(ScriptedPolicyFetcher(.offline)).snapshot()
        #expect(relaunched.bundle.bundleVersion == Self.goodVersion)
        #expect(relaunched.adDetection(provider: .openai)?.bundleVersion == Self.goodVersion)
        guard case .downloaded = relaunched.source else {
            Issue.record("cached bundle not used: \(relaunched.source)")
            return
        }
    }

    @Test("Bad signature falls back to the baked copy and says why")
    func badSignatureFallsBack() async {
        defer { cleanUp() }
        let snapshot = await loader(ScriptedPolicyFetcher(AnalysisPolicyTestFixtures.badSignature)).refresh()
        #expect(snapshot.source == .baked)
        #expect(snapshot.fallbackReason == .signatureInvalid("signature did not verify"))
        #expect(snapshot.fallbackReason?.code == "signature_invalid")
    }

    @Test("A bundle for a newer app build falls back to the baked copy and says why")
    func oldAppBuildFallsBack() async {
        defer { cleanUp() }
        let snapshot = await loader(ScriptedPolicyFetcher(AnalysisPolicyTestFixtures.futureMinAppBuild)).refresh()
        #expect(snapshot.source == .baked)
        #expect(snapshot.fallbackReason == .appBuildTooOld(required: 1_000_000, actual: 301))
        #expect(snapshot.fallbackReason?.code == "min_app_build")
    }

    @Test("An attempted widening is rejected whole and named")
    func wideningRejectedWhole() async {
        defer { cleanUp() }
        let snapshot = await loader(ScriptedPolicyFetcher(AnalysisPolicyTestFixtures.widenedWindow)).refresh()
        #expect(snapshot.source == .baked)
        #expect(snapshot.bundle == .baked)
        #expect(snapshot.fallbackReason == .outOfBounds(field: "features.ad_detection.window.segments"))
        #expect(snapshot.fallbackReason?.code == "out_of_bounds:features.ad_detection.window.segments")
        #expect(snapshot.adDetection(provider: .google)?.settings.window.segments == 800)
    }

    @Test("Offline launch with no cache falls back to the baked copy and says why")
    func offlineLaunchFallsBack() async {
        defer { cleanUp() }
        let snapshot = await loader(ScriptedPolicyFetcher(.offline)).refreshIfDue()
        #expect(snapshot.source == .baked)
        #expect(snapshot.fallbackReason == .fetchFailed("url_error_\(URLError.Code.notConnectedToInternet.rawValue)"))
        #expect(snapshot.fallbackReason?.code == "fetch_failed")
    }

    @Test("A cache the server has not confirmed for 30 days goes stale")
    func staleCacheFallsBack() async {
        defer { cleanUp() }
        let fetcher = ScriptedPolicyFetcher(AnalysisPolicyTestFixtures.good)
        let loader = loader(fetcher)
        _ = await loader.refresh()
        await fetcher.serve(.offline)

        clock.advance(by: AnalysisPolicyLoader.maximumCacheAge - 60)
        let fresh = await loader.refreshIfDue()
        #expect(fresh.bundle.bundleVersion == Self.goodVersion)
        #expect(fresh.lastRefreshFailure?.code == "fetch_failed")

        clock.advance(by: 2 * 24 * 60 * 60)
        let stale = await loader.refreshIfDue()
        #expect(stale.source == .baked)
        #expect(stale.fallbackReason == .cacheStale(days: 31))
        #expect(stale.fallbackReason?.code == "cache_stale")
    }

    @Test("A rejected download never replaces an accepted bundle")
    func rejectedDownloadKeepsAcceptedBundle() async {
        defer { cleanUp() }
        let fetcher = ScriptedPolicyFetcher(AnalysisPolicyTestFixtures.good)
        let loader = loader(fetcher)
        _ = await loader.refresh()
        for fixture in [
            AnalysisPolicyTestFixtures.badSignature,
            AnalysisPolicyTestFixtures.widenedWindow,
            AnalysisPolicyTestFixtures.futureMinAppBuild,
        ] {
            await fetcher.serve(fixture)
            let snapshot = await loader.refresh()
            #expect(snapshot.bundle.bundleVersion == Self.goodVersion)
            #expect(snapshot.fallbackReason == nil)
            #expect(snapshot.lastRefreshFailure != nil)
        }
    }

    @Test("A lower version than one already accepted is refused")
    func rollbackRefused() async {
        defer { cleanUp() }
        let fetcher = ScriptedPolicyFetcher(AnalysisPolicyTestFixtures.next)
        let loader = loader(fetcher)
        #expect(await loader.refresh().bundle.bundleVersion == Self.nextVersion)
        await fetcher.serve(AnalysisPolicyTestFixtures.good)
        let snapshot = await loader.refresh()
        #expect(snapshot.bundle.bundleVersion == Self.nextVersion)
        #expect(snapshot.lastRefreshFailure == .rollback(accepted: Self.nextVersion, offered: Self.goodVersion))

        let relaunched = await self.loader(fetcher).refresh()
        #expect(relaunched.bundle.bundleVersion == Self.nextVersion)
        #expect(relaunched.lastRefreshFailure == .rollback(accepted: Self.nextVersion, offered: Self.goodVersion))
    }

    @Test("A cache below the accepted high-water mark is refused on launch")
    func cacheBelowHighWaterMarkRefused() async throws {
        defer { cleanUp() }
        let fetcher = ScriptedPolicyFetcher(AnalysisPolicyTestFixtures.good)
        _ = await loader(fetcher).refresh()
        let cacheURL = directory.appending(path: "analysis-policy.json")
        let olderCache = try Data(contentsOf: cacheURL)
        await fetcher.serve(AnalysisPolicyTestFixtures.next)
        #expect(await loader(fetcher).refresh().bundle.bundleVersion == Self.nextVersion)
        // The older file comes back under the newer high-water mark, as a
        // failed cache write beside a successful state write would leave it.
        try olderCache.write(to: cacheURL)

        let snapshot = await loader(ScriptedPolicyFetcher(.offline)).snapshot()
        #expect(snapshot.source == .baked)
        #expect(snapshot.fallbackReason == .rollback(accepted: Self.nextVersion, offered: Self.goodVersion))
    }

    @Test("A bundle that cannot be written stays active for the session and is retried")
    func persistenceFailureRetries() async throws {
        defer { cleanUp() }
        try Data().write(to: directory)
        let fetcher = ScriptedPolicyFetcher(AnalysisPolicyTestFixtures.good)
        let loader = loader(fetcher)
        let snapshot = await loader.refresh()
        #expect(snapshot.bundle.bundleVersion == Self.goodVersion)
        #expect(snapshot.lastRefreshFailure == .persistenceFailed)
        clock.advance(by: AnalysisPolicyLoader.failureRetryInterval)
        #expect(await loader.isRefreshDue())

        let relaunched = await self.loader(ScriptedPolicyFetcher(.offline)).snapshot()
        #expect(relaunched.source == .baked)
    }

    @Test("A signature fetches exactly the versioned bundle it names, and a flip moves to the next")
    func signatureNamesItsBundle() async throws {
        defer { cleanUp() }
        let fetcher = ScriptedPolicyFetcher(AnalysisPolicyTestFixtures.good)
        try await fetcher.publishBundle(of: AnalysisPolicyTestFixtures.next)
        let loader = loader(fetcher)
        #expect(await loader.refresh().bundle.bundleVersion == Self.goodVersion)
        #expect(await fetcher.fetchedPaths == ["/v1/policies/analysis.sig", "/v1/policies/analysis/\(Self.goodVersion).json"])

        await fetcher.serve(AnalysisPolicyTestFixtures.next)
        let flipped = await loader.refresh()
        #expect(flipped.bundle.bundleVersion == Self.nextVersion)
        #expect(flipped.lastRefreshFailure == nil)
        #expect(await fetcher.fetchedPaths.suffix(2) == ["/v1/policies/analysis.sig", "/v1/policies/analysis/\(Self.nextVersion).json"])
    }

    @Test("An old signature never verifies a newer body served under its version")
    func mixedGenerationNeverVerifies() async throws {
        defer { cleanUp() }
        let fetcher = ScriptedPolicyFetcher(AnalysisPolicyTestFixtures.good)
        await fetcher.replaceBundle(at: Self.goodVersion, with: PolicyTestSupport.data(AnalysisPolicyTestFixtures.next).bundle)
        let snapshot = await loader(fetcher).refresh()
        #expect(snapshot.source == .baked)
        #expect(snapshot.fallbackReason == .signatureInvalid("bundle does not match the digest its signature names"))

        let validator = AnalysisPolicyValidator(verifier: PolicyTestSupport.testVerifier, appBuild: PolicyTestSupport.appBuild)
        let next = PolicyTestSupport.data(AnalysisPolicyTestFixtures.next)
        let good = PolicyTestSupport.data(AnalysisPolicyTestFixtures.good)
        #expect(throws: AnalysisPolicyRejection.self) {
            try validator.validate(bundleData: next.bundle, signatureData: good.signature)
        }
        #expect(throws: AnalysisPolicyRejection.self) {
            try validator.validate(bundleData: good.bundle, signatureData: next.signature)
        }
    }

    @Test("A signature that still names the accepted bundle confirms it without the body")
    func unchangedSignatureConfirmsWithoutBody() async {
        defer { cleanUp() }
        let fetcher = ScriptedPolicyFetcher(AnalysisPolicyTestFixtures.good)
        let loader = loader(fetcher)
        _ = await loader.refresh()
        clock.advance(by: AnalysisPolicyLoader.refreshInterval)
        let snapshot = await loader.refresh()
        #expect(await fetcher.fetchCount == 3)
        #expect(await fetcher.fetchedPaths.last == "/v1/policies/analysis.sig")
        #expect(snapshot.source == .downloaded(confirmedAt: clock.now()))

        // A signature naming the accepted version must still verify over it.
        await fetcher.replaceSignature(with: PolicyTestSupport.data(AnalysisPolicyTestFixtures.badSignature).signature)
        let refused = await loader.refresh()
        #expect(refused.lastRefreshFailure == .signatureInvalid("signature did not verify"))
        #expect(refused.bundle.bundleVersion == Self.goodVersion)
    }

    @Test("An envelope that names no bundle is refused")
    func unboundEnvelopeRefused() async throws {
        defer { cleanUp() }
        let good = PolicyTestSupport.data(AnalysisPolicyTestFixtures.good)
        var envelope = try #require(try JSONSerialization.jsonObject(with: good.signature) as? [String: Any])
        envelope["bundle_version"] = nil
        envelope["sha256"] = nil
        let fetcher = ScriptedPolicyFetcher(AnalysisPolicyTestFixtures.good)
        await fetcher.replaceSignature(with: try JSONSerialization.data(withJSONObject: envelope))
        let snapshot = await loader(fetcher).refresh()
        #expect(snapshot.source == .baked)
        #expect(snapshot.fallbackReason == .signatureInvalid("signature does not name its bundle"))
    }

    @Test("A rollback is refused before its bundle is fetched")
    func rollbackRefusedEarly() async {
        defer { cleanUp() }
        let fetcher = ScriptedPolicyFetcher(AnalysisPolicyTestFixtures.next)
        let loader = loader(fetcher)
        _ = await loader.refresh()
        await fetcher.serve(AnalysisPolicyTestFixtures.good)
        let snapshot = await loader.refresh()
        #expect(snapshot.lastRefreshFailure == .rollback(accepted: Self.nextVersion, offered: Self.goodVersion))
        #expect(await fetcher.fetchedPaths.last == "/v1/policies/analysis.sig")
    }

    @Test("Refresh is daily after a success and hourly after a failure")
    func refreshCadence() async {
        defer { cleanUp() }
        let fetcher = ScriptedPolicyFetcher(AnalysisPolicyTestFixtures.good)
        let loader = loader(fetcher)
        _ = await loader.refreshIfDue()
        #expect(await fetcher.fetchCount == 2)

        clock.advance(by: AnalysisPolicyLoader.refreshInterval - 1)
        _ = await loader.refreshIfDue()
        #expect(await fetcher.fetchCount == 2)
        clock.advance(by: 1)
        _ = await loader.refreshIfDue()
        #expect(await fetcher.fetchCount == 3)

        await fetcher.serve(.offline)
        clock.advance(by: AnalysisPolicyLoader.refreshInterval)
        _ = await loader.refreshIfDue()
        #expect(await fetcher.fetchCount == 4)
        clock.advance(by: AnalysisPolicyLoader.failureRetryInterval - 1)
        _ = await loader.refreshIfDue()
        #expect(await fetcher.fetchCount == 4)
        clock.advance(by: 1)
        _ = await loader.refreshIfDue()
        #expect(await fetcher.fetchCount == 5)

        let relaunched = self.loader(fetcher)
        #expect(await relaunched.isRefreshDue() == false)
    }

    @Test("The served bundle at the baked version keeps the baked copy with no reason")
    func servedBakedVersionIsNotAFallback() async throws {
        defer { cleanUp() }
        let version = BakedAnalysisPolicy.bundleVersion
        let fetcher = try ScriptedPolicyFetcher(.documents(
            bundle: PolicyTestSupport.gatewayFile("manifests/analysis-policy/v\(version).json"),
            signature: PolicyTestSupport.gatewayFile("manifests/analysis-policy/v\(version).json.sig")
        ))
        let snapshot = await loader(fetcher, verifier: .pinned).refresh()
        #expect(snapshot.source == .baked)
        #expect(snapshot.fallbackReason == nil)
        #expect(snapshot.lastRefreshFailure == nil)
    }

    @Test("A corrupted cache is re-verified on launch and ignored")
    func corruptedCacheIgnored() async throws {
        defer { cleanUp() }
        _ = await loader(ScriptedPolicyFetcher(AnalysisPolicyTestFixtures.good)).refresh()
        let cacheURL = directory.appending(path: "analysis-policy.json")
        var cache = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any] ?? [:]
        cache["signature"] = Data(AnalysisPolicyTestFixtures.badSignature.signature.utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: cache).write(to: cacheURL)

        let snapshot = await loader(ScriptedPolicyFetcher(.offline)).snapshot()
        #expect(snapshot.source == .baked)
        #expect(snapshot.fallbackReason == .signatureInvalid("signature did not verify"))
    }

    @Test("Concurrent refreshes share one download")
    func concurrentRefreshesShareOneFetch() async {
        defer { cleanUp() }
        let fetcher = ScriptedPolicyFetcher(AnalysisPolicyTestFixtures.good)
        let loader = loader(fetcher)
        async let first = loader.refresh()
        async let second = loader.refresh()
        let versions = await [first.bundle.bundleVersion, second.bundle.bundleVersion]
        #expect(versions == [Self.goodVersion, Self.goodVersion])
        #expect(await fetcher.fetchCount == 2)
    }

    @Test("Oversized documents are refused before verification")
    func oversizedRefused() throws {
        let validator = AnalysisPolicyValidator(verifier: PolicyTestSupport.testVerifier, appBuild: 301)
        let huge = Data(count: AnalysisPolicyValidator.maximumBundleBytes + 1)
        #expect(throws: AnalysisPolicyRejection.tooLarge(bytes: huge.count)) {
            try validator.validate(bundleData: huge, signatureData: Data())
        }
    }
}
