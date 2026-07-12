import Foundation
import Observation
import SwiftData

@Observable
final class RecentSearchesStore {
    private static let preferenceKey = "search.recentQueries"
    private static let queryLimit = 10

    private(set) var queries: [String] = []
    private(set) var lastErrorMessage: String?

    func load(modelContext: ModelContext) {
        do {
            guard let value = try LocalPreferenceRecord.preference(
                forKey: Self.preferenceKey,
                modelContext: modelContext
            )?.value,
                  let data = value.data(using: .utf8)
            else {
                queries = []
                lastErrorMessage = nil
                return
            }

            queries = Array(
                try JSONDecoder().decode([String].self, from: data).prefix(Self.queryLimit)
            )
            lastErrorMessage = nil
        } catch {
            queries = []
            lastErrorMessage = "Unable to load recent searches: \(error.localizedDescription)"
        }
    }

    func record(_ query: String, modelContext: ModelContext) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return
        }
        guard queries.first?.caseInsensitiveCompare(trimmedQuery) != .orderedSame else {
            return
        }

        let previousQueries = queries
        queries = Array(
            ([trimmedQuery] + queries.filter {
                $0.caseInsensitiveCompare(trimmedQuery) != .orderedSame
            }).prefix(Self.queryLimit)
        )

        do {
            try persist(modelContext: modelContext)
            lastErrorMessage = nil
        } catch {
            queries = previousQueries
            lastErrorMessage = "Unable to save recent searches: \(error.localizedDescription)"
        }
    }

    func clear(modelContext: ModelContext) {
        let previousQueries = queries
        queries = []

        do {
            try LocalPreferenceRecord.deletePreferences(
                forKey: Self.preferenceKey,
                modelContext: modelContext
            )
            try modelContext.save()
            lastErrorMessage = nil
        } catch {
            queries = previousQueries
            lastErrorMessage = "Unable to clear recent searches: \(error.localizedDescription)"
        }
    }

    private func persist(modelContext: ModelContext) throws {
        let data = try JSONEncoder().encode(queries)
        let value = String(decoding: data, as: UTF8.self)

        try LocalPreferenceRecord.upsert(
            key: Self.preferenceKey,
            value: value,
            modelContext: modelContext
        )
        try modelContext.save()
    }
}
