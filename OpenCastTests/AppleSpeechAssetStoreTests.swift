import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@MainActor
@Suite("Apple speech asset store")
struct AppleSpeechAssetStoreTests {
    @Test("Refresh reports unavailable when the transcriber is unavailable")
    func refreshReportsUnavailable() async {
        let provider = FakeAppleSpeechAssetProvider(isTranscriberAvailable: false)
        let store = makeStore(provider: provider)

        await store.refresh()

        #expect(store.state == .unavailable)
        #expect(!store.isTranscriberAvailable)
        #expect(store.installedLocaleIdentifiers.isEmpty)
    }

    @Test("Refresh loads installed locales")
    func refreshLoadsInstalledLocales() async {
        let provider = FakeAppleSpeechAssetProvider(
            statusesByLocaleIdentifier: ["en_US": .installed, "fr_FR": .installed, "de_DE": .supported]
        )
        let store = makeStore(provider: provider)

        await store.refresh()

        #expect(store.state == .ready(installedLocaleIdentifiers: ["en_US", "fr_FR"]))
        #expect(store.installedLocaleIdentifiers == ["en_US", "fr_FR"])
    }

    @Test("Ensure returns immediately for installed assets without installing")
    func ensureReturnsInstalledWithoutInstalling() async throws {
        let provider = FakeAppleSpeechAssetProvider()
        let store = makeStore(provider: provider)

        let localeIdentifier = try await store.ensureInstalledAssets(forLanguageCode: "en-US")

        #expect(localeIdentifier == "en_US")
        #expect(provider.installRequests.isEmpty)
    }

    @Test("Ensure installs supported assets and publishes progress states")
    func ensureInstallsSupportedAssets() async throws {
        let provider = FakeAppleSpeechAssetProvider(
            statusesByLocaleIdentifier: ["en_US": .supported],
            installProgressFractions: [0.25, 0.75]
        )
        provider.makeInstallGate()
        let store = makeStore(provider: provider)

        let installTask = Task {
            try await store.ensureInstalledAssets(forLanguageCode: "en-US")
        }
        try await waitUntil {
            if case .installing(let localeIdentifier, let fraction) = store.state {
                return localeIdentifier == "en_US" && fraction >= 0.75
            }
            return false
        }
        provider.installGate?.yield()
        provider.installGate?.finish()

        let localeIdentifier = try await installTask.value
        #expect(localeIdentifier == "en_US")
        #expect(provider.installRequests == ["en_US"])
        #expect(store.state == .ready(installedLocaleIdentifiers: ["en_US"]))
    }

    @Test("Ensure surfaces install failure and fails the state")
    func ensureSurfacesInstallFailure() async {
        let provider = FakeAppleSpeechAssetProvider(
            statusesByLocaleIdentifier: ["en_US": .supported]
        )
        provider.installError = FakeAppleSpeechAssetProviderError.installFailed
        let store = makeStore(provider: provider)

        await #expect(throws: FakeAppleSpeechAssetProviderError.self) {
            try await store.ensureInstalledAssets(forLanguageCode: "en-US")
        }
        guard case .failed = store.state else {
            Issue.record("expected failed state, got \(store.state)")
            return
        }
    }

    @Test("Ensure throws for unsupported locale and unsupported assets")
    func ensureThrowsForUnsupported() async {
        let provider = FakeAppleSpeechAssetProvider(
            resolvedLocalesByLanguage: ["en-us": "en_US"],
            statusesByLocaleIdentifier: ["en_US": .unsupported]
        )
        let store = makeStore(provider: provider)

        await #expect(throws: AppleSpeechTranscriptionError.unsupportedLocale("xx")) {
            try await store.ensureInstalledAssets(forLanguageCode: "xx")
        }
        await #expect(throws: AppleSpeechTranscriptionError.self) {
            try await store.ensureInstalledAssets(forLanguageCode: "en-US")
        }
    }

    @Test("Install reserves the locale after success")
    func installReservesLocale() async throws {
        let provider = FakeAppleSpeechAssetProvider(
            resolvedLocalesByLanguage: ["de-de": "de_DE"],
            statusesByLocaleIdentifier: ["de_DE": .supported]
        )
        let store = makeStore(provider: provider)

        _ = try await store.ensureInstalledAssets(forLanguageCode: "de-DE")

        #expect(provider.reserveRequests == ["de_DE"])
        #expect(provider.reserved.contains("de_DE"))
    }

    @Test("Reservation cap releases the least recently used locale")
    func reservationCapReleasesLeastRecentlyUsed() async throws {
        let provider = FakeAppleSpeechAssetProvider(
            maximumReservedLocales: 2,
            resolvedLocalesByLanguage: ["de-de": "de_DE"],
            statusesByLocaleIdentifier: ["de_DE": .supported],
            reserved: ["en_US", "fr_FR"]
        )
        let store = makeStore(provider: provider)
        store.recordLocaleUsed("fr_FR")
        try await Task.sleep(for: .milliseconds(5))
        store.recordLocaleUsed("en_US")

        _ = try await store.ensureInstalledAssets(forLanguageCode: "de-DE")

        #expect(provider.releasedLocaleIdentifiers == ["fr_FR"])
        #expect(provider.reserved.sorted() == ["de_DE", "en_US"])
    }

    private func makeStore(provider: FakeAppleSpeechAssetProvider) -> AppleSpeechAssetStore {
        let suiteName = "apple-speech-asset-store-tests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        userDefaults.removePersistentDomain(forName: suiteName)
        return AppleSpeechAssetStore(provider: provider, userDefaults: userDefaults)
    }

    // Generous deadline: under full-suite parallel load the unstructured
    // install/progress tasks can wait a long time for scheduling; this only
    // bounds a genuinely broken run.
    private func waitUntil(
        timeout: Duration = .seconds(120),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition not met before timeout")
    }
}
