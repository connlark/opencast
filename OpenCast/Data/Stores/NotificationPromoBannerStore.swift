import Foundation
import Observation
import SwiftData

@Observable
final class NotificationPromoBannerStore {
    static let resolvedPreferenceKey = "notifications.promoBanner.resolved"
    private static let resolvedPreferenceValue = "true"

    private(set) var isResolved = false
    private(set) var lastErrorMessage: String?

    func load(modelContext: ModelContext) {
        do {
            isResolved = try Self.storedResolved(modelContext: modelContext)
            lastErrorMessage = nil
        } catch {
            isResolved = false
            lastErrorMessage = "Unable to load notification banner state: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func markResolved(modelContext: ModelContext) -> Bool {
        guard !isResolved else {
            return true
        }

        isResolved = true
        do {
            try LocalPreferenceRecord.upsert(
                key: Self.resolvedPreferenceKey,
                value: Self.resolvedPreferenceValue,
                modelContext: modelContext
            )
            try modelContext.save()
            lastErrorMessage = nil
            return true
        } catch {
            isResolved = false
            lastErrorMessage = "Unable to save notification banner state: \(error.localizedDescription)"
            return false
        }
    }

    func resetAfterDataNuke() {
        isResolved = false
        lastErrorMessage = nil
    }

    private static func storedResolved(modelContext: ModelContext) throws -> Bool {
        try LocalPreferenceRecord.preference(
            forKey: resolvedPreferenceKey,
            modelContext: modelContext
        )?.value == resolvedPreferenceValue
    }
}
