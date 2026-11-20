import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders

final class AnalysisRouteResolver {
    private let keys: AnalysisProviderKeyStore
    private let policy: AnalysisPolicySnapshotStore
    private let storedProvider: (AnalysisFeature) -> AnalysisProvider?
    private let trialStatus: AnalysisTrialStatusCache
    private let trial: any AnalysisTrialConnecting
    private let trialReachability: AnalysisTrialReachability
    private let runs: AnalysisRunRecordStore
    private let now: () -> Date

    init(
        keys: AnalysisProviderKeyStore,
        policy: AnalysisPolicySnapshotStore,
        storedProvider: @escaping (AnalysisFeature) -> AnalysisProvider?,
        trialStatus: AnalysisTrialStatusCache,
        trial: any AnalysisTrialConnecting,
        trialReachability: AnalysisTrialReachability,
        runs: AnalysisRunRecordStore,
        now: @escaping () -> Date = { Date.now }
    ) {
        self.keys = keys
        self.policy = policy
        self.storedProvider = storedProvider
        self.trialStatus = trialStatus
        self.trial = trial
        self.trialReachability = trialReachability
        self.runs = runs
        self.now = now
    }

    var isTrialRouteConfigured: Bool {
        trial.isConfigured
    }

    /// A trial resume needs no unit: the trial already admitted the run.
    func resolve(feature: AnalysisFeature, resumingRunID: String? = nil) async -> AnalysisRouteResolution {
        trialReachability.start()
        let snapshot = policy.snapshot
        if let resumingRunID, let record = runs.record(id: resumingRunID), record.feature == feature,
           record.state == .dispatched || record.state == .expired,
           let resumed = await resume(record, snapshot: snapshot) {
            return await withHandoverWindow(resumed)
        }
        return await withHandoverWindow(await resolveNew(feature: feature, snapshot: snapshot))
    }

    private func withHandoverWindow(_ resolution: AnalysisRouteResolution) async -> AnalysisRouteResolution {
        guard resolution.feature == .adDetection, resolution.route == .direct(provider: .google) else {
            return resolution
        }
        var windowed = resolution
        windowed.freeTierHandover = await isHandoverWindowOpen()
        return windowed
    }

    /// Decided with no request to opencast, so a paid key's run never waits
    /// on opencast's service.
    func isHandoverWindowOpen() async -> Bool {
        await trialReachability.resolve()
        return trialReachability.isHandoverWindowOpen(trialStartsAt: policy.snapshot.bundle.trial.startsAt, now: now())
    }

    /// The only fact that ends a handover for good; an unreachable service may come back.
    var isPastTrialDate: Bool {
        !(now() < policy.snapshot.bundle.trial.startsAt)
    }

    /// Refreshes the status: the answer must be the service's, not an hour-old copy. The date is
    /// read again after each wait, so a reply landing past it starts no trial record, and a passed
    /// date outranks an unanswered service because retrying would not help.
    func resolveHandover(feature: AnalysisFeature) async -> AnalysisHandoverResolution {
        let reachability = await trialReachability.resolve()
        guard !isPastTrialDate else {
            return .notOpen
        }
        let snapshot = policy.snapshot
        guard reachability == .available,
              let trialPolicy = Self.trialPolicy(feature: feature, snapshot: snapshot),
              let exchange = await trial.exchange(trialEndpoint: snapshot.bundle.trial.endpoint),
              let status = await trialStatus.status(forceRefresh: true)
        else {
            return isPastTrialDate ? .notOpen : .unavailable
        }
        guard status.mode == .open, !isPastTrialDate else {
            return .notOpen
        }
        return .available(AnalysisRouteResolution(
            feature: feature,
            route: .trial,
            policy: trialPolicy,
            key: nil,
            resumingRunID: nil,
            trialExchange: exchange
        ))
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

    /// Reads each key from the Keychain itself, never a presence cache that may be unread. A failed
    /// read is `keychainUnreadable`, never "no key", unless the stored choice read a key; `nil`
    /// means no provider holds one.
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

    /// `nil` resolves the run as a new one.
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

    nonisolated static func directPolicy(feature: AnalysisFeature, provider: AnalysisProvider, snapshot: AnalysisPolicySnapshot) -> AnalysisRoutePolicy? {
        switch feature {
        case .adDetection: snapshot.adDetection(provider: provider).map(AnalysisRoutePolicy.adDetection)
        case .chaptersSummary: snapshot.chaptersSummary(provider: provider).map(AnalysisRoutePolicy.chaptersSummary)
        }
    }

    /// Ad detection runs one window at a time: the trial admits one open request per install.
    nonisolated static func trialPolicy(feature: AnalysisFeature, snapshot: AnalysisPolicySnapshot) -> AnalysisRoutePolicy? {
        switch feature {
        case .adDetection:
            guard let trial = snapshot.trialAdDetection else { return nil }
            var settings = trial.settings
            settings.window.maxInFlight = 1
            return .adDetection(trial.with(settings: settings, executionBudget: .trial))
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
