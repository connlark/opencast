import Foundation
import SwiftData

/// The only spelling of a synced-store save. The save and the arbiter credit
/// are one call, so a synced write cannot land without the credit that lets
/// `SyncedStoreRemoteChangeArbiter` swallow the notification it round-trips
/// (one credit per save). Saves that touch only the local store must not
/// come through here: a credit with no matching synced-store notification
/// swallows the next genuine remote change until the foreground backstop
/// refresh, so in DEBUG the ledger asserts that a synced row is dirty.
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
            model is SubscriptionRecord || model is EpisodeProgressRecord || model is SyncTombstoneRecord
        }
    }
    #endif
}
