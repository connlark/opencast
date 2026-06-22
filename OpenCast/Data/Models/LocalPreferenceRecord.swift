import Foundation
import SwiftData

@Model
final class LocalPreferenceRecord {
    var key: String = ""
    var value: String = ""
    var updatedAt: Date = Date()

    init(key: String, value: String, updatedAt: Date = Date()) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
    }

    static func preference(
        forKey key: String,
        modelContext: ModelContext
    ) throws -> LocalPreferenceRecord? {
        var descriptor = FetchDescriptor<LocalPreferenceRecord>(
            predicate: #Predicate<LocalPreferenceRecord> { record in
                record.key == key
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    static func upsert(
        key: String,
        value: String,
        modelContext: ModelContext
    ) throws {
        let record: LocalPreferenceRecord
        if let existingRecord = try preference(forKey: key, modelContext: modelContext) {
            record = existingRecord
        } else {
            record = LocalPreferenceRecord(key: key, value: value)
            modelContext.insert(record)
        }

        record.value = value
        record.updatedAt = .now
    }

    static func deletePreferences(
        forKey key: String,
        modelContext: ModelContext
    ) throws {
        let descriptor = FetchDescriptor<LocalPreferenceRecord>(
            predicate: #Predicate<LocalPreferenceRecord> { record in
                record.key == key
            }
        )
        for record in try modelContext.fetch(descriptor) {
            modelContext.delete(record)
        }
    }
}
