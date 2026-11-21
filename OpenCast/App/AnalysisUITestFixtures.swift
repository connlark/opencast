import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Security
import SwiftData
import Synchronization

enum AnalysisUITestFixtures {
    /// Joined from parts so no source file holds a key-shaped literal for the
    /// secret scanners to flag. Never a real key.
    static func keyText(for provider: AnalysisProvider) -> String {
        switch provider {
        case .google: ["AIza", "FixtureKeyForUITestsOnly", "00000000000"].joined()
        case .openai: ["sk-", "fixture-", "uitests-only-0123456789"].joined()
        }
    }

    static func key(for provider: AnalysisProvider) -> AnalysisProviderKey {
        guard let key = AnalysisProviderKey(keyText(for: provider)) else {
            fatalError("The \(provider.rawValue) fixture key is empty")
        }
        return key
    }

    static func policySnapshot(variant: String?) -> AnalysisPolicySnapshot {
        var bundle = AnalysisPolicyBundle.baked
        switch variant ?? "baked" {
        case "no-openai-chapters":
            bundle.features.chaptersSummary.allowedModels.removeAll { $0.provider == .openai }
        case "second-google-model":
            bundle.features.adDetection.additionalModels = secondGoogleModel(of: bundle.features.adDetection.qualifiedModels)
            bundle.features.chaptersSummary.additionalModels = secondGoogleModel(of: bundle.features.chaptersSummary.allowedModels)
            let ad = bundle.features.adDetection
            let chapters = bundle.features.chaptersSummary
            let listed = Set((ad.qualifiedModels + ad.additionalModels + chapters.allowedModels + chapters.additionalModels).map(\.identity))
            bundle.modelCards.removeAll { !listed.contains($0.identity) }
        case "trial-started":
            bundle.trial.startsAt = bundle.generatedAt
        default:
            return .baked
        }
        return AnalysisPolicySnapshot(bundle: bundle, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
    }

    private static func secondGoogleModel(of defaults: [AnalysisModelEntry]) -> [AnalysisModelEntry] {
        defaults.filter { $0.provider == .google }.map { entry in
            var second = entry
            second.modelID = "gemini-second"
            second.label = "Gemini Second"
            return second
        }
    }

    static func trialStatus(_ rawValue: String?) -> AnalysisTrialStatus? {
        let unitsPrefix = "units-left-"
        switch rawValue ?? "" {
        case "not-started":
            return .notStarted
        case "exhausted":
            return .exhausted
        case let value where value.hasPrefix(unitsPrefix):
            guard let units = Int(value.dropFirst(unitsPrefix.count)), units >= 0 else {
                return nil
            }
            return .unitsLeft(units)
        default:
            return nil
        }
    }

    static func keyTestResults(_ rawValue: String?) -> [AnalysisKeyTestResult]? {
        let results = (rawValue ?? "").split(separator: ",").compactMap { keyTestResult(String($0)) }
        return results.isEmpty ? nil : results
    }

    nonisolated struct KeyStorageFailure: Equatable, Sendable {
        var operation: AnalysisProviderKeyStoreError.Operation
        var synchronizable: Bool
    }

    static func keyStorageFailures(_ rawValue: String?) -> [KeyStorageFailure]? {
        let failures = (rawValue ?? "").split(separator: ",").compactMap { entry -> KeyStorageFailure? in
            let parts = entry.split(separator: "-")
            guard parts.count == 2, let operation = AnalysisProviderKeyStoreError.Operation(rawValue: String(parts[0])) else {
                return nil
            }
            switch parts[1] {
            case "local": return KeyStorageFailure(operation: operation, synchronizable: false)
            case "synced": return KeyStorageFailure(operation: operation, synchronizable: true)
            default: return nil
            }
        }
        return failures.isEmpty ? nil : failures
    }

    nonisolated static func keyStorageFault(failing failures: [KeyStorageFailure]) -> InMemoryAnalysisProviderKeyStorage.Fault {
        let pending = PendingFailures(failures)
        return { operation, synchronizable in
            pending.take(KeyStorageFailure(operation: operation, synchronizable: synchronizable)) ? errSecNotAvailable : nil
        }
    }

    private nonisolated final class PendingFailures: Sendable {
        private let remaining: Mutex<[KeyStorageFailure]>

        init(_ failures: [KeyStorageFailure]) {
            remaining = Mutex(failures)
        }

        func take(_ call: KeyStorageFailure) -> Bool {
            remaining.withLock { remaining in
                guard let index = remaining.firstIndex(of: call) else {
                    return false
                }
                remaining.remove(at: index)
                return true
            }
        }
    }

    static func keyTestResult(_ rawValue: String?) -> AnalysisKeyTestResult? {
        guard let rawValue else {
            return nil
        }
        if rawValue == "accepted" {
            return .accepted
        }
        return AnalysisProviderFailure(rawValue: rawValue).map { .failed($0) }
    }

    static func seedKeyNoticeSeen(in container: ModelContainer) throws {
        let context = ModelContext(container)
        try LocalPreferenceRecord.upsert(
            key: AnalysisKeyNoticeStore.seenPreferenceKey,
            value: AnalysisKeyNoticeStore.seenPreferenceValue,
            modelContext: context
        )
        try context.save()
    }
}
