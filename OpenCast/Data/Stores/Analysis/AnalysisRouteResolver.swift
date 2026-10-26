import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders

/// Decides each run's route before its record is written: the listener's
/// key when one is saved for the feature's provider, else the trial while
/// it has room (or the run is a resume the trial already admitted), else
/// the key screen. A Keychain read that fails is never "no key", and the
/// trial is never a fallback for it; nothing here ever routes to
/// opencast's older analysis services.
final class AnalysisRouteResolver {
    private let keys: AnalysisProviderKeyStore
    private let policy: AnalysisPolicySnapshotStore
    private let storedProvider: (AnalysisFeature) -> AnalysisProvider?
    private let trialStatus: AnalysisTrialStatusCache
    private let trial: any AnalysisTrialConnecting
    private let runs: AnalysisRunRecordStore

    init(
        keys: AnalysisProviderKeyStore,
        policy: AnalysisPolicySnapshotStore,
        storedProvider: @escaping (AnalysisFeature) -> AnalysisProvider?,
        trialStatus: AnalysisTrialStatusCache,
        trial: any AnalysisTrialConnecting,
        runs: AnalysisRunRecordStore
    ) {
        self.keys = keys
        self.policy = policy
        self.storedProvider = storedProvider
        self.trialStatus = trialStatus
        self.trial = trial
        self.runs = runs
    }

    /// Whether this build and device can use a trial route at all; no
    /// request is made.
    var isTrialRouteConfigured: Bool {
        trial.isConfigured
    }

    /// The route for one run of `feature`. `resumingRunID` names a run
    /// record to resume under the same id: it keeps its route when the run
    /// is still open (`dispatched` or `expired`) and its route still applies
    /// under the same policy, and a trial resume needs no unit.
    func resolve(feature: AnalysisFeature, resumingRunID: String? = nil) async -> AnalysisRouteResolution {
        let snapshot = policy.snapshot
        if let resumingRunID, let record = runs.record(id: resumingRunID), record.feature == feature,
           record.state == .dispatched || record.state == .expired,
           let resumed = await resume(record, snapshot: snapshot) {
            return resumed
        }
        return await resolveNew(feature: feature, snapshot: snapshot)
    }

    private func resolveNew(feature: AnalysisFeature, snapshot: AnalysisPolicySnapshot) async -> AnalysisRouteResolution {
        if let direct = directResolution(feature: feature, snapshot: snapshot) {
            return direct
        }
        let trialResolution = await trialResolution(feature: feature, snapshot: snapshot)
        // A key saved while the trial was being asked about wins over
        // whatever the trial answered.
        if let direct = directResolution(feature: feature, snapshot: snapshot) {
            return direct
        }
        return trialResolution
    }

    private func trialResolution(feature: AnalysisFeature, snapshot: AnalysisPolicySnapshot) async -> AnalysisRouteResolution {
        guard let trialPolicy = Self.trialPolicy(feature: feature, snapshot: snapshot),
              let exchange = await trial.exchange(trialEndpoint: snapshot.bundle.trial.endpoint),
              let status = await trialStatus.status(forceRefresh: false)
        else {
            return .keyRequired(.proxyUnavailable, feature: feature)
        }
        switch status.mode {
        case .open:
            break
        case .trial:
            if status.monthPaused { return .keyRequired(.trialPaused, feature: feature) }
            if status.unitsRemaining <= 0 { return .keyRequired(.trialExhausted, feature: feature) }
        }
        return AnalysisRouteResolution(
            feature: feature,
            route: .trial,
            policy: trialPolicy,
            key: nil,
            resumingRunID: nil,
            trialExchange: exchange
        )
    }

    /// The direct route when the Keychain holds a key for a provider with an
    /// entry for `feature`. Every such provider's key is read from the
    /// Keychain itself (a presence cache that has not been read yet never
    /// reads as "no key"), then the listener's provider rule picks among the
    /// providers that hold one: the stored choice, else the only one, else
    /// Google. A read that fails is `keychainUnreadable` unless the stored
    /// choice itself read a key; `nil` means none holds a key.
    private func directResolution(feature: AnalysisFeature, snapshot: AnalysisPolicySnapshot) -> AnalysisRouteResolution? {
        let stored = storedProvider(feature)
        var eligible: [(provider: AnalysisProvider, key: AnalysisProviderKey, policy: AnalysisRoutePolicy)] = []
        var unreadable = false
        for provider in AnalysisProvider.allCases {
            guard let routePolicy = Self.directPolicy(feature: feature, provider: provider, snapshot: snapshot) else { continue }
            do {
                if let key = try keys.key(for: provider) {
                    eligible.append((provider, key, routePolicy))
                }
            } catch {
                unreadable = true
            }
        }
        let storedMatch = stored.flatMap { stored in eligible.first { $0.provider == stored } }
        if storedMatch == nil, unreadable {
            return .keyRequired(.keychainUnreadable, feature: feature)
        }
        guard let pick = storedMatch ?? AnalysisProviderSelectionStore
            .effectiveProvider(stored: stored, eligible: eligible.map(\.provider))
            .flatMap({ provider in eligible.first { $0.provider == provider } })
        else {
            return nil
        }
        return AnalysisRouteResolution(
            feature: feature,
            route: .direct(provider: pick.provider),
            policy: pick.policy,
            key: pick.key,
            resumingRunID: nil,
            trialExchange: nil
        )
    }

    /// The resumed run's route, when its route and policy still apply;
    /// `nil` to resolve it as a new run.
    private func resume(_ record: AnalysisRunRecord, snapshot: AnalysisPolicySnapshot) async -> AnalysisRouteResolution? {
        switch record.route {
        case .direct:
            guard let routePolicy = Self.directPolicy(feature: record.feature, provider: record.provider, snapshot: snapshot),
                  Self.matches(record, routePolicy)
            else {
                return nil
            }
            let key: AnalysisProviderKey?
            do {
                key = try keys.key(for: record.provider)
            } catch {
                return .keyRequired(.keychainUnreadable, feature: record.feature)
            }
            guard let key else { return nil }
            return AnalysisRouteResolution(
                feature: record.feature,
                route: .direct(provider: record.provider),
                policy: routePolicy,
                key: key,
                resumingRunID: record.id,
                trialExchange: nil
            )
        case .trial:
            guard let routePolicy = Self.trialPolicy(feature: record.feature, snapshot: snapshot),
                  Self.matches(record, routePolicy)
            else {
                return nil
            }
            guard let exchange = await trial.exchange(trialEndpoint: snapshot.bundle.trial.endpoint) else {
                return .keyRequired(.proxyUnavailable, feature: record.feature)
            }
            return AnalysisRouteResolution(
                feature: record.feature,
                route: .trial,
                policy: routePolicy,
                key: nil,
                resumingRunID: record.id,
                trialExchange: exchange
            )
        }
    }

    nonisolated static func matches(_ record: AnalysisRunRecord, _ policy: AnalysisRoutePolicy) -> Bool {
        record.modelID == policy.model.modelID
            && record.bundleVersion == policy.bundleVersion
            && record.policyRevision == policy.revision
    }

    /// The listener's provider entry for the feature; `nil` when the bundle
    /// has none.
    nonisolated static func directPolicy(feature: AnalysisFeature, provider: AnalysisProvider, snapshot: AnalysisPolicySnapshot) -> AnalysisRoutePolicy? {
        switch feature {
        case .adDetection: snapshot.adDetection(provider: provider).map(AnalysisRoutePolicy.adDetection)
        case .chaptersSummary: snapshot.chaptersSummary(provider: provider).map(AnalysisRoutePolicy.chaptersSummary)
        }
    }

    /// The trial's entry: the Google entry with the trial's model id. Ad
    /// detection runs one window at a time, because the trial service
    /// admits one open request per install.
    nonisolated static func trialPolicy(feature: AnalysisFeature, snapshot: AnalysisPolicySnapshot) -> AnalysisRoutePolicy? {
        switch feature {
        case .adDetection:
            guard let trial = snapshot.trialAdDetection else { return nil }
            var settings = trial.settings
            settings.window.maxInFlight = 1
            return .adDetection(trial.with(settings: settings))
        case .chaptersSummary:
            guard let entry = snapshot.chaptersSummary(provider: .google),
                  entry.model.modelID == snapshot.bundle.trial.modelID
            else {
                return nil
            }
            return .chaptersSummary(entry)
        }
    }
}
