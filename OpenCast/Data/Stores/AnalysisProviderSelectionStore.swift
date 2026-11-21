import Foundation
import Observation
import OpenCastAnalysis
import SwiftData

/// The effective provider and model are derived, never stored: a choice whose key is removed stays
/// stored and comes back with the key.
@Observable
final class AnalysisProviderSelectionStore {
    static let adDetectionPreferenceKey = "aiServices.provider.adDetection"
    static let chaptersSummaryPreferenceKey = "aiServices.provider.chaptersSummary"
    static let adDetectionModelPreferenceKey = "aiServices.model.adDetection"
    static let chaptersSummaryModelPreferenceKey = "aiServices.model.chaptersSummary"

    nonisolated struct StoredChoice: Equatable, Sendable {
        var provider: AnalysisProvider
        /// `nil`: the provider's default entry applies.
        var modelID: String?
    }

    private(set) var storedChoices: [AnalysisFeature: StoredChoice] = [:]
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

    static func modelPreferenceKey(for feature: AnalysisFeature) -> String {
        switch feature {
        case .adDetection: adDetectionModelPreferenceKey
        case .chaptersSummary: chaptersSummaryModelPreferenceKey
        }
    }

    func load(modelContext: ModelContext) {
        let context = ModelContext(modelContext.container)
        do {
            var choices: [AnalysisFeature: StoredChoice] = [:]
            for feature in AnalysisFeature.allCases {
                let provider = try LocalPreferenceRecord.preference(
                    forKey: Self.preferenceKey(for: feature),
                    modelContext: context
                )?.value
                let modelID = try LocalPreferenceRecord.preference(
                    forKey: Self.modelPreferenceKey(for: feature),
                    modelContext: context
                )?.value
                choices[feature] = provider.flatMap(AnalysisProvider.init(rawValue:)).map {
                    StoredChoice(provider: $0, modelID: modelID)
                }
            }
            storedChoices = choices
            lastErrorMessage = nil
        } catch {
            storedChoices = [:]
            lastErrorMessage = "Unable to load AI Services providers: \(error.localizedDescription)"
        }
    }

    func storedChoice(for feature: AnalysisFeature) -> StoredChoice? {
        storedChoices[feature]
    }

    @discardableResult
    func select(_ model: AnalysisModelIdentity, for feature: AnalysisFeature, modelContext: ModelContext) -> Bool {
        let choice = StoredChoice(provider: model.provider, modelID: model.modelID)
        guard storedChoices[feature] != choice else {
            return true
        }
        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        do {
            try LocalPreferenceRecord.upsert(
                key: Self.preferenceKey(for: feature),
                value: model.provider.rawValue,
                modelContext: context
            )
            try LocalPreferenceRecord.upsert(
                key: Self.modelPreferenceKey(for: feature),
                value: model.modelID,
                modelContext: context
            )
            try save(context)
        } catch {
            lastErrorMessage = "Unable to update the AI Services model: \(error.localizedDescription)"
            return false
        }
        storedChoices[feature] = choice
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

    /// Each eligible provider's default entry, then its additional entries.
    func modelOptions(
        for feature: AnalysisFeature,
        presences: [AnalysisProvider: AnalysisKeyPresence],
        snapshot: AnalysisPolicySnapshot
    ) -> [AnalysisModelEntry] {
        eligibleProviders(for: feature, presences: presences, snapshot: snapshot).flatMap {
            snapshot.modelEntries(for: feature, provider: $0)
        }
    }

    func effectiveProvider(
        for feature: AnalysisFeature,
        presences: [AnalysisProvider: AnalysisKeyPresence],
        snapshot: AnalysisPolicySnapshot
    ) -> AnalysisProvider? {
        Self.effectiveProvider(
            stored: storedChoices[feature]?.provider,
            eligible: eligibleProviders(for: feature, presences: presences, snapshot: snapshot)
        )
    }

    func effectiveModel(
        for feature: AnalysisFeature,
        presences: [AnalysisProvider: AnalysisKeyPresence],
        snapshot: AnalysisPolicySnapshot
    ) -> AnalysisModelEntry? {
        effectiveProvider(for: feature, presences: presences, snapshot: snapshot).flatMap { provider in
            Self.effectiveModel(for: feature, provider: provider, stored: storedChoices[feature], snapshot: snapshot)
        }
    }

    /// Google comes after the stored choice because it is the trial's provider.
    static func effectiveProvider(stored: AnalysisProvider?, eligible: [AnalysisProvider]) -> AnalysisProvider? {
        if let stored, eligible.contains(stored) {
            return stored
        }
        return eligible.contains(.google) ? .google : eligible.first
    }

    /// The stored model applies only under its own provider and while the snapshot lists it, so a
    /// fallback provider never picks up a same-named model.
    nonisolated static func effectiveModel(
        for feature: AnalysisFeature,
        provider: AnalysisProvider,
        stored: StoredChoice?,
        snapshot: AnalysisPolicySnapshot
    ) -> AnalysisModelEntry? {
        if let stored, stored.provider == provider, let modelID = stored.modelID,
           let entry = snapshot.modelEntries(for: feature, provider: provider).first(where: { $0.modelID == modelID }) {
            return entry
        }
        return snapshot.modelEntry(for: feature, provider: provider)
    }
}
