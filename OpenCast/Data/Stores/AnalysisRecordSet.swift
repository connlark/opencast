import Foundation
import Observation
import SwiftData

/// One analysis store's loaded records, the O(1) episode index over them,
/// and the fetch/commit machinery that keeps both in step with SwiftData.
@Observable
final class AnalysisRecordSet<Record: TranscriptDerivedAnalysisRecord> {
    // The index rebuilds on every mutation (didSet), so per-row lookups stay
    // O(1) and can never go stale; keep-first mirrors the replaced
    // `records.first` lookup (house precedent: LibraryStore.episodeIndexByID).
    private(set) var records: [Record] = [] {
        didSet {
            recordsRevision &+= 1
            recordsByEpisodeID = Dictionary(
                records.map { ($0.episodeID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }
    @ObservationIgnored private var recordsByEpisodeID: [String: Record] = [:]
    // Pairs the ignored index with a tracked revision so `record(for:)`
    // registers a dependency even when it returns nil — a body that saw no
    // record must still invalidate when one appears (house pattern:
    // LibraryStore.progressIndexRevision).
    private var recordsRevision = 0
    @ObservationIgnored private let descriptors: AnalysisRecordFetchDescriptors<Record>

    init(descriptors: AnalysisRecordFetchDescriptors<Record>) {
        self.descriptors = descriptors
    }

    func record(for episodeID: String) -> Record? {
        _ = recordsRevision
        return recordsByEpisodeID[episodeID]
    }

    func reload(modelContext: ModelContext) throws {
        records = try fetchRecords(modelContext: modelContext)
    }

    func removeAll() {
        records.removeAll()
    }

    /// Saves, then republishes the episode's stored row — or drops the
    /// loaded one when the save left nothing behind.
    func commit(episodeID: String, modelContext: ModelContext, resort: Bool = false) throws {
        try modelContext.save()
        if let record = try fetchStoredRecord(episodeID: episodeID, modelContext: modelContext) {
            updateLoadedRecord(record, resort: resort)
        } else {
            records.removeAll { $0.episodeID == episodeID }
        }
    }

    func fetchStoredRecord(episodeID: String, modelContext: ModelContext) throws -> Record? {
        var descriptor = descriptors.forEpisodeID(episodeID)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func fetchRecords(episodeID: String, modelContext: ModelContext) throws -> [Record] {
        try modelContext.fetch(descriptors.forEpisodeID(episodeID))
    }

    func fetchRecords(forPodcastID podcastID: String, modelContext: ModelContext) throws -> [Record] {
        try modelContext.fetch(descriptors.forPodcastID(podcastID))
    }

    func fetchRecords(modelContext: ModelContext) throws -> [Record] {
        try modelContext.fetch(descriptors.all())
    }

    private func updateLoadedRecord(_ record: Record, resort: Bool) {
        if let index = records.firstIndex(where: { $0.episodeID == record.episodeID }) {
            records[index] = record
        } else {
            records.append(record)
        }

        if resort {
            records.sort { $0.updatedAt > $1.updatedAt }
        }
    }
}
