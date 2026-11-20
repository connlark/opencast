import Foundation
import Observation
import OpenCastAnalysis
import SwiftData

/// The effective provider is derived, never stored: a choice whose key is removed stays stored
/// and comes back with the key.
@Observable
final class AnalysisProviderSelectionStore {
    static let adDetectionPreferenceKey = "aiServices.provider.adDetection"
    static let chaptersSummaryPreferenceKey = "aiServices.provider.chaptersSummary"

    private(set) var storedProviders: [AnalysisFeature: AnalysisProvider] = [:]
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let save: (ModelContext) throws -> Void

    init(save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.save = save
    }

    static func preferenceKey(for feature: AnalysisFeature) -> String {
        switch feature {
        case .adDetection: adDetectionPreferenceKey
        case .chaptersSummary: chaptersSummaryPreferenceKey
        }
    }

    func load(modelContext: ModelContext) {
        let context = ModelContext(modelContext.container)
        do {
            var providers: [AnalysisFeature: AnalysisProvider] = [:]
            for feature in AnalysisFeature.allCases {
                let value = try LocalPreferenceRecord.preference(
                    forKey: Self.preferenceKey(for: feature),
                    modelContext: context
                )?.value
                providers[feature] = value.flatMap(AnalysisProvider.init(rawValue:))
            }
            storedProviders = providers
            lastErrorMessage = nil
        } catch {
            storedProviders = [:]
            lastErrorMessage = "Unable to load AI Services providers: \(error.localizedDescription)"
        }
    }

    func storedProvider(for feature: AnalysisFeature) -> AnalysisProvider? {
        storedProviders[feature]
    }

    @discardableResult
    func setProvider(_ provider: AnalysisProvider, for feature: AnalysisFeature, modelContext: ModelContext) -> Bool {
        guard storedProviders[feature] != provider else {
            return true
        }
        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        do {
            try LocalPreferenceRecord.upsert(
                key: Self.preferenceKey(for: feature),
                value: provider.rawValue,
                modelContext: context
            )
            try save(context)
        } catch {
            lastErrorMessage = "Unable to update the AI Services provider: \(error.localizedDescription)"
            return false
        }
        storedProviders[feature] = provider
        lastErrorMessage = nil
        return true
    }

    func eligibleProviders(
        for feature: AnalysisFeature,
        presences: [AnalysisProvider: AnalysisKeyPresence],
        snapshot: AnalysisPolicySnapshot
    ) -> [AnalysisProvider] {
        AnalysisProvider.allCases.filter { provider in
            (presences[provider] ?? AnalysisKeyPresence.none).isSaved
                && snapshot.modelEntry(for: feature, provider: provider) != nil
        }
    }

    func effectiveProvider(
        for feature: AnalysisFeature,
        presences: [AnalysisProvider: AnalysisKeyPresence],
        snapshot: AnalysisPolicySnapshot
    ) -> AnalysisProvider? {
        Self.effectiveProvider(
            stored: storedProviders[feature],
            eligible: eligibleProviders(for: feature, presences: presences, snapshot: snapshot)
        )
    }

    /// Google comes after the stored choice because it is the trial's provider.
    static func effectiveProvider(stored: AnalysisProvider?, eligible: [AnalysisProvider]) -> AnalysisProvider? {
        if let stored, eligible.contains(stored) {
            return stored
        }
        return eligible.contains(.google) ? .google : eligible.first
    }
}
