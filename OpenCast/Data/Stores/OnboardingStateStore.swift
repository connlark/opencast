import Foundation
import Observation
import SwiftData

@Observable
final class OnboardingStateStore {
    static let completedPreferenceKey = "onboarding.completed"
    private static let completedPreferenceValue = "true"

    private(set) var isCompleted = false
    private(set) var lastErrorMessage: String?

    var shouldPresentOnboarding: Bool {
        !isCompleted
    }

    func load(modelContext: ModelContext) {
        do {
            let value = try LocalPreferenceRecord.preference(
                forKey: Self.completedPreferenceKey,
                modelContext: modelContext
            )?.value
            let hasCompletedPreference = value == Self.completedPreferenceValue
            let hasActiveSubscriptions = hasCompletedPreference
                ? false
                : try hasActiveSubscriptions(modelContext: modelContext)
            isCompleted = hasCompletedPreference || hasActiveSubscriptions
            lastErrorMessage = nil
            if hasActiveSubscriptions && !hasCompletedPreference {
                do {
                    try persistCompletedPreference(modelContext: modelContext)
                } catch {
                    lastErrorMessage = "Unable to save onboarding state: \(error.localizedDescription)"
                }
            }
        } catch {
            isCompleted = false
            lastErrorMessage = "Unable to load onboarding state: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func markCompleted(modelContext: ModelContext) -> Bool {
        guard !isCompleted else {
            return true
        }

        isCompleted = true
        do {
            try persistCompletedPreference(modelContext: modelContext)
            lastErrorMessage = nil
            return true
        } catch {
            isCompleted = false
            lastErrorMessage = "Unable to complete onboarding: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func reset(modelContext: ModelContext) -> Bool {
        do {
            let key = Self.completedPreferenceKey
            let records = try modelContext.fetch(
                FetchDescriptor<LocalPreferenceRecord>(
                    predicate: #Predicate<LocalPreferenceRecord> { record in
                        record.key == key
                    }
                )
            )
            for record in records {
                modelContext.delete(record)
            }
            try modelContext.save()
            isCompleted = false
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "Unable to reset onboarding: \(error.localizedDescription)"
            return false
        }
    }

    private func hasActiveSubscriptions(modelContext: ModelContext) throws -> Bool {
        var descriptor = FetchDescriptor<SubscriptionRecord>(
            predicate: #Predicate<SubscriptionRecord> { record in
                !record.isArchived
            }
        )
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    private func persistCompletedPreference(modelContext: ModelContext) throws {
        try LocalPreferenceRecord.upsert(
            key: Self.completedPreferenceKey,
            value: Self.completedPreferenceValue,
            modelContext: modelContext
        )
        try modelContext.save()
    }
}
