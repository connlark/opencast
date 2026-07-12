import Foundation
import Observation
import OpenCastTranscription

/// Apple Speech asset lifecycle for the resolver, onboarding, and settings:
/// per-locale status, install-with-progress, and locale reservation. The
/// system inventory sits behind `AppleSpeechAssetProviding` for testability.
@Observable
final class AppleSpeechAssetStore {
    private static let localeLastUsedDefaultsKey = "appleSpeech.localeLastUsedAt"

    private(set) var state: AppleSpeechAssetState = .unknown

    @ObservationIgnored private let provider: any AppleSpeechAssetProviding
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let stateChanges = StoreChangeNotifier()
    @ObservationIgnored private var installTask: Task<String, Error>?

    init(
        provider: any AppleSpeechAssetProviding = LiveAppleSpeechAssetProvider(),
        userDefaults: UserDefaults = .standard
    ) {
        self.provider = provider
        self.userDefaults = userDefaults
    }

    var isTranscriberAvailable: Bool {
        provider.isTranscriberAvailable
    }

    var installedLocaleIdentifiers: [String] {
        if case .ready(let identifiers) = state {
            return identifiers
        }
        return []
    }

    var changeSequence: Int {
        stateChanges.sequence
    }

    func waitForChange(after sequence: Int) async throws {
        try await stateChanges.wait(after: sequence)
    }

    func refresh() async {
        guard provider.isTranscriberAvailable else {
            setState(.unavailable)
            return
        }

        if case .installing = state {
            return
        }

        setState(.checking)
        let installed = await provider.installedLocaleIdentifiers()
        setState(.ready(installedLocaleIdentifiers: installed))
    }

    func resolvedLocaleIdentifier(forLanguageCode languageCode: String) async -> String? {
        guard provider.isTranscriberAvailable else {
            return nil
        }
        return await provider.supportedLocaleIdentifier(equivalentTo: languageCode)
    }

    func status(forLanguageCode languageCode: String) async -> (localeIdentifier: String?, status: AppleSpeechAssetLocaleStatus?) {
        guard provider.isTranscriberAvailable else {
            return (nil, nil)
        }
        guard let localeIdentifier = await provider.supportedLocaleIdentifier(equivalentTo: languageCode) else {
            return (nil, nil)
        }
        return (localeIdentifier, await provider.status(forLocaleIdentifier: localeIdentifier))
    }

    /// Resolves the locale for `languageCode` and installs its assets when
    /// they are installable, publishing install progress through `state`.
    /// Returns the installed locale identifier.
    func ensureInstalledAssets(forLanguageCode languageCode: String) async throws -> String {
        guard provider.isTranscriberAvailable else {
            setState(.unavailable)
            throw AppleSpeechTranscriptionError.transcriberUnavailable
        }

        guard let localeIdentifier = await provider.supportedLocaleIdentifier(equivalentTo: languageCode) else {
            throw AppleSpeechTranscriptionError.unsupportedLocale(languageCode)
        }

        switch await provider.status(forLocaleIdentifier: localeIdentifier) {
        case .installed:
            recordLocaleUsed(localeIdentifier)
            return localeIdentifier
        case .unsupported:
            throw AppleSpeechTranscriptionError.unsupportedAssets(
                localeIdentifier: localeIdentifier,
                status: AppleSpeechAssetLocaleStatus.unsupported.rawValue
            )
        case .supported, .downloading:
            break
        }

        if let installTask {
            let installedLocaleIdentifier = try await installTask.value
            guard installedLocaleIdentifier == localeIdentifier else {
                return try await ensureInstalledAssets(forLanguageCode: languageCode)
            }
            recordLocaleUsed(localeIdentifier)
            return installedLocaleIdentifier
        }

        let task = Task {
            try await installAssets(forLocaleIdentifier: localeIdentifier)
        }
        installTask = task
        defer {
            installTask = nil
        }

        let installedLocaleIdentifier = try await task.value
        recordLocaleUsed(installedLocaleIdentifier)
        return installedLocaleIdentifier
    }

    func recordLocaleUsed(_ localeIdentifier: String) {
        var usage = localeLastUsedAt
        usage[localeIdentifier] = Date.now.timeIntervalSinceReferenceDate
        userDefaults.set(usage, forKey: Self.localeLastUsedDefaultsKey)
    }

    private func installAssets(forLocaleIdentifier localeIdentifier: String) async throws -> String {
        setState(.installing(localeIdentifier: localeIdentifier, fractionCompleted: 0))
        AdFreePassBackgroundRunLog.record("apple assets install starting locale=\(localeIdentifier)")

        do {
            try await provider.installAssets(forLocaleIdentifier: localeIdentifier) { fraction in
                Task { @MainActor [weak self] in
                    self?.noteInstallProgress(localeIdentifier: localeIdentifier, fractionCompleted: fraction)
                }
            }
        } catch {
            AdFreePassBackgroundRunLog.record(
                "apple assets install failed locale=\(localeIdentifier) error=\(error.localizedDescription)"
            )
            setState(.failed(error.localizedDescription))
            throw error
        }

        AdFreePassBackgroundRunLog.record("apple assets install completed locale=\(localeIdentifier)")
        await reserveAfterInstall(localeIdentifier)
        let installed = await provider.installedLocaleIdentifiers()
        setState(.ready(installedLocaleIdentifiers: installed))
        return localeIdentifier
    }

    /// Reservation policy: reserve on first successful install; when the
    /// system cap is hit, release the least-recently-transcribed locale.
    private func reserveAfterInstall(_ localeIdentifier: String) async {
        let maximum = provider.maximumReservedLocales
        let reservedBefore = await provider.reservedLocaleIdentifiers()
        AdFreePassBackgroundRunLog.record(
            "apple assets reservation maximumReservedLocales=\(maximum) reservedBefore=\(reservedBefore.joined(separator: ","))"
        )
        guard !reservedBefore.contains(localeIdentifier) else {
            return
        }

        do {
            try await provider.reserveLocale(localeIdentifier)
        } catch {
            let releasable = leastRecentlyUsedLocale(from: reservedBefore)
            guard let releasable else {
                AdFreePassBackgroundRunLog.record(
                    "apple assets reserve failed locale=\(localeIdentifier) error=\(error.localizedDescription) noReleasableLocale"
                )
                return
            }

            let released = await provider.releaseLocale(releasable)
            AdFreePassBackgroundRunLog.record(
                "apple assets released locale=\(releasable) released=\(released) toMakeRoomFor=\(localeIdentifier)"
            )
            do {
                try await provider.reserveLocale(localeIdentifier)
            } catch {
                AdFreePassBackgroundRunLog.record(
                    "apple assets reserve retry failed locale=\(localeIdentifier) error=\(error.localizedDescription)"
                )
            }
        }

        let reservedAfter = await provider.reservedLocaleIdentifiers()
        AdFreePassBackgroundRunLog.record(
            "apple assets reservation reservedAfter=\(reservedAfter.joined(separator: ","))"
        )
    }

    private func noteInstallProgress(localeIdentifier: String, fractionCompleted: Double) {
        // Progress callbacks hop to the main actor as independent tasks and
        // can arrive out of order; published install progress stays monotonic.
        guard case .installing(let currentLocaleIdentifier, let currentFraction) = state,
              currentLocaleIdentifier == localeIdentifier,
              fractionCompleted > currentFraction
        else {
            return
        }
        setState(.installing(localeIdentifier: localeIdentifier, fractionCompleted: fractionCompleted))
    }

    private func leastRecentlyUsedLocale(from reserved: [String]) -> String? {
        guard !reserved.isEmpty else {
            return nil
        }
        let usage = localeLastUsedAt
        return reserved.min { lhs, rhs in
            (usage[lhs] ?? 0) < (usage[rhs] ?? 0)
        }
    }

    private var localeLastUsedAt: [String: Double] {
        userDefaults.dictionary(forKey: Self.localeLastUsedDefaultsKey) as? [String: Double] ?? [:]
    }

    private func setState(_ newState: AppleSpeechAssetState) {
        guard state != newState else {
            return
        }
        state = newState
        stateChanges.notify()
    }
}
