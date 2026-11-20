import Foundation
import SwiftData

/// Every synced-store save goes through here, and nothing else does: a credit without a
/// matching synced-store notification swallows the next genuine remote change.
final class SyncedStoreSelfSaveLedger {
    private(set) var count = 0
    private let performSave: (ModelContext) throws -> Void

    init(performSave: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.performSave = performSave
    }

    func save(_ modelContext: ModelContext) throws {
        #if DEBUG
        assert(
            Self.dirtiesSyncedStore(modelContext),
            "A synced-store save was credited without a dirty synced row."
        )
        #endif
        try performSave(modelContext)
        count += 1
    }

    #if DEBUG
    private static func dirtiesSyncedStore(_ modelContext: ModelContext) -> Bool {
        let dirtiedModels = modelContext.insertedModelsArray
            + modelContext.changedModelsArray
            + modelContext.deletedModelsArray
        return dirtiedModels.contains { model in
            model is SubscriptionRecord
                || model is EpisodeProgressRecord
                || model is SyncTombstoneRecord
                || model is PlaylistRecord
                || model is PlaylistItemRecord
                || model is PlaylistTombstoneRecord
        }
    }
    #endif
}
