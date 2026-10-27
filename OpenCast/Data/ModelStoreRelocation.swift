import Foundation

/// Moves each SwiftData store out of the App Group container into the app's
/// data container before any `ModelContainer` opens: RunningBoard kills a
/// process suspended while it holds a lock on a file outside its own data
/// container (`0xdead10cc`), and Core Data takes such locks on its own queues.
///
/// While a group `.store` exists it is the only writable location, whatever
/// its state, so a failed check never hands authority to the stale app-side
/// copy. The rename of the main file is the commit: everything before it
/// repeats on the next launch, everything after it is cleanup that the next
/// launch's branch 1 finishes.
nonisolated enum ModelStoreRelocation {
    typealias Deferral = ModelStoreRelocationResult.Deferral

    /// One store, the plan's branches in order. Never throws and never traps:
    /// every failure is a deferral or a note.
    static func relocate(
        _ store: ModelStoreLocation,
        operations: any ModelStoreFileOperations = DefaultModelStoreFileOperations()
    ) -> ModelStoreRelocationResult {
        let group = Package(storeURL: store.groupURL)
        let app = Package(storeURL: store.appURL)
        let groupStatus: ModelStoreFileStatus?
        do {
            groupStatus = try operations.status(at: group.storeURL)
        } catch {
            return result(
                store,
                resolvedURL: store.groupURL,
                outcome: .deferred(.inaccessible("probe \(group.storeName): \(describe(error))"))
            )
        }
        guard groupStatus != nil else {
            return settleWithoutGroupStore(store, group: group, app: app, operations: operations)
        }
        return move(store, group: group, app: app, operations: operations)
    }

    /// Both stores, synced then local, each independent. Returns the layout
    /// with both `resolvedURL`s set and the two results in that order.
    static func relocate(
        _ layout: ModelStoreLayout,
        operations: any ModelStoreFileOperations = DefaultModelStoreFileOperations()
    ) -> (layout: ModelStoreLayout, results: [ModelStoreRelocationResult]) {
        let synced = relocate(layout.synced, operations: operations)
        let local = relocate(layout.local, operations: operations)
        var relocated = layout
        relocated.synced.resolvedURL = synced.resolvedURL
        relocated.local.resolvedURL = local.resolvedURL
        return (relocated, [synced, local])
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? LocalLibraryCacheStoreError {
            return "\(error.operation): \(error.message)"
        }
        let error = error as NSError
        return "\(error.domain) \(error.code): \(error.localizedDescription)"
    }

    // MARK: - Branch 1

    /// Group absence is confirmed, so the app URL resolves whatever else
    /// happens: a container opened at the group URL now would create a group
    /// store that the next relocation would move over the complete app one.
    private static func settleWithoutGroupStore(
        _ store: ModelStoreLocation,
        group: Package,
        app: Package,
        operations: any ModelStoreFileOperations
    ) -> ModelStoreRelocationResult {
        let appStatus: ModelStoreFileStatus?
        do {
            appStatus = try operations.status(at: app.storeURL)
        } catch {
            return result(
                store,
                resolvedURL: store.appURL,
                outcome: .inPlace,
                notes: ["probe \(app.storeName): \(describe(error))"]
            )
        }
        guard appStatus != nil else {
            return settleWithoutAnyStore(store, group: group, operations: operations)
        }
        return result(
            store,
            resolvedURL: store.appURL,
            outcome: .inPlace,
            notes: removeGroupLeftovers(group, operations: operations)
        )
    }

    /// A fresh install, or a state nothing foresaw: delete nothing.
    private static func settleWithoutAnyStore(
        _ store: ModelStoreLocation,
        group: Package,
        operations: any ModelStoreFileOperations
    ) -> ModelStoreRelocationResult {
        let leftovers: [String]
        do {
            leftovers = try groupDirectoryExists(group, operations: operations)
                ? group.packageEntryNames(operations: operations)
                : []
        } catch {
            return result(
                store,
                resolvedURL: store.appURL,
                outcome: .inPlace,
                notes: ["list \(group.directory.lastPathComponent): \(describe(error))"]
            )
        }
        return result(
            store,
            resolvedURL: store.appURL,
            outcome: leftovers.isEmpty ? .inPlace : .ambiguous,
            notes: leftovers.map { "group leftover kept: \($0)" }
        )
    }

    /// The leftovers of a crash after the commit, whose contents were copied
    /// before it. A `-journal` or an unforeseen entry stays.
    private static func removeGroupLeftovers(
        _ group: Package,
        operations: any ModelStoreFileOperations
    ) -> [String] {
        let inventory: Package.Inventory
        do {
            guard try groupDirectoryExists(group, operations: operations) else {
                return []
            }
            inventory = try group.inventory(operations: operations)
        } catch {
            return ["list \(group.directory.lastPathComponent): \(describe(error))"]
        }
        let removable = inventory.sidecars.filter { $0 != group.journalName } + inventory.companions
        var notes = removable.map { name in
            remove(name, in: group, operations: operations) ?? "removed group leftover \(name)"
        }
        notes += (inventory.sidecars.filter { $0 == group.journalName } + inventory.unforeseen)
            .map { "group leftover kept: \($0)" }
        return notes
    }

    private static func groupDirectoryExists(
        _ group: Package,
        operations: any ModelStoreFileOperations
    ) throws -> Bool {
        try operations.status(at: group.directory) != nil
    }

    // MARK: - Steps 2 to 6

    private static func move(
        _ store: ModelStoreLocation,
        group: Package,
        app: Package,
        operations: any ModelStoreFileOperations
    ) -> ModelStoreRelocationResult {
        let source = validateSource(group, operations: operations)
        if let deferral = source.deferral {
            return result(store, resolvedURL: store.groupURL, outcome: .deferred(deferral), source: source)
        }
        var notes: [String] = []
        if let failure = clearDestination(app, notes: &notes, operations: operations) {
            return result(
                store,
                resolvedURL: store.groupURL,
                outcome: .deferred(.interrupted(.clearDestination, failure)),
                source: source,
                notes: notes
            )
        }
        if let failure = copyCompanions(source.companions, from: group, to: app, operations: operations) {
            return result(
                store,
                resolvedURL: store.groupURL,
                outcome: .deferred(.interrupted(.copyCompanions, failure)),
                source: source,
                notes: notes
            )
        }
        if let deferral = commit(group: group, app: app, operations: operations) {
            return result(store, resolvedURL: store.groupURL, outcome: .deferred(deferral), source: source, notes: notes)
        }
        notes += [group.walName, group.shmName].compactMap { remove($0, in: group, operations: operations) }
        notes += source.companions.compactMap { remove($0, in: group, operations: operations) }
        return result(store, resolvedURL: store.appURL, outcome: .moved, source: source, notes: notes)
    }

    /// Step 3. Nothing writes at the app URL while a group store exists, so
    /// what sits there is the stale copy from 2026-09-13 or a partial earlier
    /// attempt. Its sidecars go whatever their type: a stale log or journal
    /// beside the moved file would be replayed into it.
    private static func clearDestination(
        _ app: Package,
        notes: inout [String],
        operations: any ModelStoreFileOperations
    ) -> String? {
        do {
            try operations.createDirectory(at: app.directory)
        } catch {
            return "create \(app.directory.lastPathComponent): \(describe(error))"
        }
        let inventory: Package.Inventory
        do {
            inventory = try app.inventory(operations: operations)
        } catch {
            return "list \(app.directory.lastPathComponent): \(describe(error))"
        }
        notes += inventory.unforeseen
            .filter { !app.sidecarNames.contains($0) }
            .map { "app entry outside the package rule kept: \($0)" }
        for name in [app.storeName] + app.sidecarNames + inventory.companions {
            if let failure = remove(name, in: app, operations: operations) {
                return failure
            }
        }
        return nil
    }

    /// Step 4. A partial copy is cleared by the next launch's step 3.
    private static func copyCompanions(
        _ companions: [String],
        from group: Package,
        to app: Package,
        operations: any ModelStoreFileOperations
    ) -> String? {
        for name in companions {
            do {
                try operations.copyItem(at: group.url(name), to: app.url(name))
            } catch {
                return "copy \(name): \(describe(error))"
            }
        }
        return nil
    }

    /// Step 5. A rename is atomic only within one volume, and the source
    /// stays intact on any failure.
    private static func commit(
        group: Package,
        app: Package,
        operations: any ModelStoreFileOperations
    ) -> Deferral? {
        let groupDirectory: ModelStoreFileStatus?
        let appDirectory: ModelStoreFileStatus?
        do {
            groupDirectory = try operations.status(at: group.directory)
            appDirectory = try operations.status(at: app.directory)
        } catch {
            return .inaccessible("probe directories: \(describe(error))")
        }
        guard let groupDirectory, let appDirectory else {
            return .inaccessible("a store directory is missing at the commit")
        }
        guard groupDirectory.deviceNumber == appDirectory.deviceNumber else {
            return .unsupported(
                "device numbers differ: group \(groupDirectory.deviceNumber), app \(appDirectory.deviceNumber)"
            )
        }
        do {
            try operations.rename(group.storeURL, to: app.storeURL)
        } catch {
            return .interrupted(.commit, "rename \(group.storeName): \(describe(error))")
        }
        return nil
    }

    /// nil on success; otherwise the failure as a note.
    private static func remove(
        _ name: String,
        in package: Package,
        operations: any ModelStoreFileOperations
    ) -> String? {
        do {
            try operations.removeItem(at: package.url(name))
            return nil
        } catch {
            return "remove \(name): \(describe(error))"
        }
    }

    private static func result(
        _ store: ModelStoreLocation,
        resolvedURL: URL,
        outcome: ModelStoreRelocationResult.Outcome,
        source: SourceValidation = SourceValidation(),
        notes: [String] = []
    ) -> ModelStoreRelocationResult {
        ModelStoreRelocationResult(
            configurationName: store.configurationName,
            resolvedURL: resolvedURL,
            outcome: outcome,
            storeUUID: source.storeUUID,
            walSize: source.walSize,
            companions: source.companions,
            notes: notes
        )
    }
}
