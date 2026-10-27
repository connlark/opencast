import Foundation
import Testing
@testable import OpenCast

@Suite("Model store relocation")
struct ModelStoreRelocationTests {
    private typealias Fixture = ModelStoreRelocationFixture
    private typealias Faults = FaultInjectingModelStoreFileOperations

    private static let support = ".SyncedUserData_SUPPORT"
    private static let assets = "SyncedUserData_ckAssets"

    enum DeferralKind: Equatable {
        case invalid, inaccessible, unsupported
        case interrupted(ModelStoreRelocationResult.Step)
    }

    // MARK: - Moves

    @Test("A store whose rows exist only in its -wal moves, and a fresh connection at the app URL answers them")
    func rowsOnlyInTheLogMove() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.location()
        let uuid = UUID().uuidString
        try fixture.writeStoreWithRowsInTheLog(at: store.groupURL, uuid: uuid, rows: ["one", "two", "three"])

        let result = ModelStoreRelocation.relocate(store)

        #expect(result.outcome == .moved)
        #expect(result.resolvedURL == store.appURL)
        #expect(result.notes.isEmpty)
        #expect(!Fixture.exists(store.groupURL))
        #expect(try Fixture.packageEntries(at: fixture.groupDirectory).isEmpty)
        #expect(try Fixture.contents(of: store.appURL) == Fixture.StoreContents(uuid: uuid, rows: ["one", "two", "three"]))
    }

    @Test("Companions with nested contents arrive byte for byte, after a stale app-side copy is cleared")
    func companionsArriveIntactOverAStaleCopy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.location()
        let uuid = try writeSourceReadyToMove(fixture, store: store)
        let outside = ["Unrelated.store", "resume-widget.json"]
        for name in outside {
            try Data(name.utf8).write(to: fixture.groupDirectory.appending(path: name))
        }
        let groupPackage = try Fixture.packageEntries(at: fixture.groupDirectory)
        let staleSupport = try Fixture.tree(at: fixture.appDirectory.appending(path: Self.support))
        let groupSupport = try Fixture.tree(at: fixture.groupDirectory.appending(path: Self.support))
        #expect(staleSupport != groupSupport)

        let result = ModelStoreRelocation.relocate(store)

        #expect(result.outcome == .moved)
        #expect(result.notes.isEmpty)
        try expectCleanEndState(fixture, groupPackageBeforeTheRun: groupPackage)
        for name in outside {
            #expect(try Data(contentsOf: fixture.groupDirectory.appending(path: name)) == Data(name.utf8))
        }
        #expect(try Fixture.contents(of: store.appURL) == Fixture.StoreContents(uuid: uuid, rows: Self.groupRows))
    }

    @Test("A second run after a move is a no-op that keeps the app URL")
    func secondRunIsANoOp() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.location()
        _ = try writeSourceReadyToMove(fixture, store: store)
        #expect(ModelStoreRelocation.relocate(store).outcome == .moved)
        let appTree = try Fixture.tree(at: fixture.appDirectory)
        let operations = Faults()

        let result = ModelStoreRelocation.relocate(store, operations: operations)

        #expect(result.outcome == .inPlace)
        #expect(result.resolvedURL == store.appURL)
        #expect(result.notes.isEmpty)
        #expect(operations.mutations.isEmpty)
        #expect(try Fixture.tree(at: fixture.appDirectory) == appTree)
    }

    @Test("A fresh install resolves to the app URL and creates nothing", arguments: [false, true])
    func freshInstallCreatesNothing(groupDirectoryExists: Bool) throws {
        let fixture = try Fixture(createsDirectories: false)
        defer { fixture.remove() }
        if groupDirectoryExists {
            try FileManager.default.createDirectory(at: fixture.groupDirectory, withIntermediateDirectories: true)
        }
        let store = fixture.location()
        let operations = Faults()

        let result = ModelStoreRelocation.relocate(store, operations: operations)

        #expect(result.outcome == .inPlace)
        #expect(result.resolvedURL == store.appURL)
        #expect(result.notes.isEmpty)
        #expect(operations.mutations.isEmpty)
        #expect(!Fixture.exists(fixture.appDirectory))
    }

    @Test("An install from before the App Group keeps its app store, -wal and companions untouched")
    func preAppGroupInstallIsUntouched() throws {
        let fixture = try Fixture(createsDirectories: false)
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.appDirectory, withIntermediateDirectories: true)
        let store = fixture.location()
        let uuid = UUID().uuidString
        let walSize = try fixture.writeStoreWithRowsInTheLog(at: store.appURL, uuid: uuid, rows: ["kept"])
        try Fixture.writeCompanions(in: fixture.appDirectory, seed: "app")
        let appTree = try Fixture.tree(at: fixture.appDirectory)
        let operations = Faults()

        let result = ModelStoreRelocation.relocate(store, operations: operations)

        #expect(result.outcome == .inPlace)
        #expect(result.resolvedURL == store.appURL)
        #expect(result.notes.isEmpty)
        #expect(operations.mutations.isEmpty)
        #expect(try Fixture.tree(at: fixture.appDirectory) == appTree)
        #expect(walSize > 0)
        #expect(try Fixture.size(of: Fixture.sidecar(store.appURL, "-wal")) == walSize)
        #expect(try Fixture.contents(of: store.appURL) == Fixture.StoreContents(uuid: uuid, rows: ["kept"]))
    }

    // MARK: - Resume

    enum Interruption: CaseIterable, Sendable {
        case beforeClearingTheDestination
        case partwayThroughClearingTheDestination
        case beforeCopyingTheCompanions
        case partwayThroughCopyingTheCompanions
        case beforeTheDeviceCheck
        case atTheRename
        case beforeTheCleanup
        case partwayThroughTheCleanup

        /// Steps 3 to 5 leave the source authoritative; step 6 runs after
        /// the commit.
        var expectedDeferral: DeferralKind? {
            switch self {
            case .beforeClearingTheDestination, .partwayThroughClearingTheDestination:
                .interrupted(.clearDestination)
            case .beforeCopyingTheCompanions, .partwayThroughCopyingTheCompanions:
                .interrupted(.copyCompanions)
            case .beforeTheDeviceCheck:
                .inaccessible
            case .atTheRename:
                .interrupted(.commit)
            case .beforeTheCleanup, .partwayThroughTheCleanup:
                nil
            }
        }

        func arm(_ operations: FaultInjectingModelStoreFileOperations, fixture: ModelStoreRelocationFixture, store: ModelStoreLocation) {
            let group = fixture.groupDirectory
            let support = ModelStoreRelocationTests.support
            let assets = ModelStoreRelocationTests.assets
            switch self {
            case .beforeClearingTheDestination:
                operations.fail(.createDirectory, at: fixture.appDirectory)
            case .partwayThroughClearingTheDestination:
                operations.stopPartway(.removeItem, at: fixture.appDirectory.appending(path: support))
            case .beforeCopyingTheCompanions:
                operations.fail(.copyItem, at: group.appending(path: support))
            case .partwayThroughCopyingTheCompanions:
                operations.stopPartway(.copyItem, at: group.appending(path: assets))
            case .beforeTheDeviceCheck:
                operations.fail(.status, at: fixture.appDirectory)
            case .atTheRename:
                operations.fail(.rename, at: store.groupURL, with: .EXDEV)
            case .beforeTheCleanup:
                for url in [
                    ModelStoreRelocationFixture.sidecar(store.groupURL, "-wal"),
                    ModelStoreRelocationFixture.sidecar(store.groupURL, "-shm"),
                    group.appending(path: support),
                    group.appending(path: assets)
                ] {
                    operations.fail(.removeItem, at: url)
                }
            case .partwayThroughTheCleanup:
                operations.stopPartway(.removeItem, at: group.appending(path: support))
            }
        }
    }

    @Test("A failure before or partway through each mutation step resumes to the clean move's end state", arguments: Interruption.allCases)
    func everyMutationBoundaryResumes(_ interruption: Interruption) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.location()
        let uuid = try writeSourceReadyToMove(fixture, store: store)
        let groupPackage = try Fixture.packageEntries(at: fixture.groupDirectory)
        let operations = Faults()
        interruption.arm(operations, fixture: fixture, store: store)

        let first = ModelStoreRelocation.relocate(store, operations: operations)

        #expect(first.storeUUID == uuid)
        if let expectedDeferral = interruption.expectedDeferral {
            #expect(Self.deferralKind(first) == expectedDeferral)
            #expect(first.resolvedURL == store.groupURL)
            #expect(try Fixture.packageEntries(at: fixture.groupDirectory) == groupPackage)
        } else {
            #expect(first.outcome == .moved)
            #expect(first.resolvedURL == store.appURL)
            #expect(!first.notes.isEmpty)
            #expect(try Fixture.packageEntries(at: fixture.appDirectory) == Self.cleanAppPackage(from: groupPackage))
            #expect(!(try Fixture.packageEntries(at: fixture.groupDirectory)).isEmpty)
        }
        try expectPartialState(after: interruption, fixture: fixture, groupPackage: groupPackage)

        let second = ModelStoreRelocation.relocate(store)

        let expectedSecondOutcome: ModelStoreRelocationResult.Outcome = interruption.expectedDeferral == nil ? .inPlace : .moved
        #expect(second.outcome == expectedSecondOutcome)
        #expect(second.resolvedURL == store.appURL)
        try expectCleanEndState(fixture, groupPackageBeforeTheRun: groupPackage)
        #expect(try Fixture.contents(of: store.appURL) == Fixture.StoreContents(uuid: uuid, rows: Self.groupRows))
    }

    /// The partway faults really stopped inside a tree.
    private func expectPartialState(after interruption: Interruption, fixture: Fixture, groupPackage: [String: Fixture.Entry]) throws {
        switch interruption {
        case .partwayThroughClearingTheDestination:
            let remaining = try Fixture.tree(at: fixture.appDirectory.appending(path: Self.support))
            #expect(Self.fileCount(remaining) == 3)
        case .partwayThroughCopyingTheCompanions:
            let copiedAssets = try Fixture.tree(at: fixture.appDirectory.appending(path: Self.assets))
            let copiedSupport = try Fixture.tree(at: fixture.appDirectory.appending(path: Self.support))
            let groupSupport = try Fixture.tree(at: fixture.groupDirectory.appending(path: Self.support))
            #expect(Self.fileCount(copiedAssets) == 2)
            #expect(copiedSupport == groupSupport)
        case .partwayThroughTheCleanup:
            let remaining = try Fixture.tree(at: fixture.groupDirectory.appending(path: Self.support))
            #expect(Self.fileCount(remaining) == 2)
            #expect(!Fixture.exists(fixture.groupDirectory.appending(path: Self.assets)))
        case .beforeTheCleanup:
            #expect(try Fixture.packageEntries(at: fixture.groupDirectory)
                == groupPackage.filter { $0.key != "SyncedUserData.store" })
        default:
            break
        }
    }

    // MARK: - Authority

    enum UnusableGroupStore: CaseIterable, Sendable {
        case empty
        case notSQLite

        var contents: Data {
            switch self {
            case .empty: Data()
            case .notSQLite: Data(String(repeating: "not a database, only text. ", count: 200).utf8)
            }
        }

        /// An empty file reads as a new rollback-mode database; a text file
        /// fails the first statement with SQLITE_NOTADB.
        var expectedDeferral: DeferralKind {
            switch self {
            case .empty: .unsupported
            case .notSQLite: .inaccessible
            }
        }
    }

    @Test("An empty or non-SQLite group store beside a valid app store defers and deletes nothing", arguments: UnusableGroupStore.allCases)
    func unusableGroupStoreDefers(_ groupStore: UnusableGroupStore) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.location()
        try Fixture.writeStore(at: store.appURL, uuid: UUID().uuidString, rows: ["app"])
        try groupStore.contents.write(to: store.groupURL)
        let appTree = try Fixture.tree(at: fixture.appDirectory)
        let groupTree = try Fixture.tree(at: fixture.groupDirectory)
        let operations = Faults()

        let result = ModelStoreRelocation.relocate(store, operations: operations)

        #expect(Self.deferralKind(result) == groupStore.expectedDeferral)
        #expect(result.resolvedURL == store.groupURL)
        #expect(operations.mutations.isEmpty)
        #expect(try Fixture.tree(at: fixture.appDirectory) == appTree)
        #expect(try Fixture.tree(at: fixture.groupDirectory) == groupTree)
    }

    enum UnopenableGroupStore: CaseIterable, Sendable {
        case directoryAtTheStorePath
        case noPermissions
        case readOnly
    }

    @Test("A group store that cannot be opened read-write is inaccessible", arguments: UnopenableGroupStore.allCases)
    func unopenableGroupStoreIsInaccessible(_ groupStore: UnopenableGroupStore) throws {
        let fixture = try Fixture()
        let store = fixture.location()
        defer {
            if groupStore != .directoryAtTheStorePath {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.groupURL.path(percentEncoded: false))
            }
            fixture.remove()
        }
        try Fixture.writeStore(at: store.appURL, uuid: UUID().uuidString, rows: ["app"])
        switch groupStore {
        case .directoryAtTheStorePath:
            try FileManager.default.createDirectory(at: store.groupURL, withIntermediateDirectories: true)
        case .noPermissions, .readOnly:
            try Fixture.writeStore(at: store.groupURL, uuid: UUID().uuidString, rows: ["group"])
            try FileManager.default.setAttributes(
                [.posixPermissions: groupStore == .noPermissions ? 0o000 : 0o444],
                ofItemAtPath: store.groupURL.path(percentEncoded: false)
            )
        }
        let appTree = try Fixture.tree(at: fixture.appDirectory)
        let operations = Faults()

        let result = ModelStoreRelocation.relocate(store, operations: operations)

        #expect(Self.deferralKind(result) == .inaccessible)
        #expect(result.resolvedURL == store.groupURL)
        #expect(operations.mutations.isEmpty)
        #expect(try Fixture.tree(at: fixture.appDirectory) == appTree)
    }

    @Test("A group store probe failing with something other than ENOENT defers with no cleanup")
    func groupProbeErrorDefersWithoutCleanup() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.location()
        try Fixture.writeStore(at: store.appURL, uuid: UUID().uuidString, rows: ["app"])
        try writeGroupLeftovers(fixture, store: store)
        let groupTree = try Fixture.tree(at: fixture.groupDirectory)
        let operations = Faults()
        operations.answerStatus(.failure(.EIO), for: store.groupURL)

        let result = ModelStoreRelocation.relocate(store, operations: operations)

        #expect(Self.deferralKind(result) == .inaccessible)
        #expect(result.resolvedURL == store.groupURL)
        #expect(operations.mutations.isEmpty)
        #expect(try Fixture.tree(at: fixture.groupDirectory) == groupTree)
    }

    enum LeftoverFailure: CaseIterable, Sendable {
        case enumeration
        case deletion
        case appProbe
    }

    @Test("After confirmed group absence, a leftover or app-side probe failure keeps the app URL with a note", arguments: LeftoverFailure.allCases)
    func leftoverFailuresKeepTheAppURL(_ failure: LeftoverFailure) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.location()
        try Fixture.writeStore(at: store.appURL, uuid: UUID().uuidString, rows: ["app"])
        try writeGroupLeftovers(fixture, store: store)
        let groupTree = try Fixture.tree(at: fixture.groupDirectory)
        let operations = Faults()
        switch failure {
        case .enumeration:
            operations.fail(.entryNames, at: fixture.groupDirectory)
        case .deletion:
            operations.fail(.removeItem, at: fixture.groupDirectory.appending(path: Self.support))
        case .appProbe:
            operations.answerStatus(.failure(.EIO), for: store.appURL)
        }

        let result = ModelStoreRelocation.relocate(store, operations: operations)

        #expect(result.outcome == .inPlace)
        #expect(result.resolvedURL == store.appURL)
        #expect(result.notes.contains { $0.contains("NSPOSIXErrorDomain") })
        switch failure {
        case .enumeration, .appProbe:
            #expect(operations.mutations.isEmpty)
            #expect(try Fixture.tree(at: fixture.groupDirectory) == groupTree)
        case .deletion:
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.groupDirectory.path(percentEncoded: false)) == [Self.support])
        }

        let second = ModelStoreRelocation.relocate(store)

        #expect(second.outcome == .inPlace)
        #expect(second.resolvedURL == store.appURL)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.groupDirectory.path(percentEncoded: false)).isEmpty)
    }

    @Test("A -journal reported after the clean close defers")
    func journalAfterTheCloseIsUnsupported() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.location()
        _ = try writeSourceReadyToMove(fixture, store: store)
        let groupPackage = try Fixture.packageEntries(at: fixture.groupDirectory)
        let operations = Faults()
        operations.answerStatus(
            .exists(ModelStoreFileStatus(isDirectory: false, size: 512, deviceNumber: 1)),
            for: Fixture.sidecar(store.groupURL, "-journal")
        )

        let result = ModelStoreRelocation.relocate(store, operations: operations)

        #expect(Self.deferralKind(result) == .unsupported)
        #expect(Self.deferralMessage(result).contains("-journal"))
        #expect(result.resolvedURL == store.groupURL)
        #expect(operations.mutations.isEmpty)
        #expect(try Fixture.packageEntries(at: fixture.groupDirectory) == groupPackage)
    }

    /// The fixture carries a `-shm` but no `-wal`: SQLite opens any database
    /// that has a `-wal` beside it in WAL mode, whatever its header says.
    @Test("A journal mode other than WAL defers before any checkpoint and leaves the sidecars alone")
    func rollbackJournalModeIsUnsupported() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.location()
        try Fixture.writeStore(at: store.groupURL, uuid: UUID().uuidString, rows: Self.groupRows, journalMode: "DELETE")
        let shm = Data(repeating: 0x5A, count: 32_768)
        try shm.write(to: Fixture.sidecar(store.groupURL, "-shm"))
        let groupTree = try Fixture.tree(at: fixture.groupDirectory)
        let operations = Faults()

        let result = ModelStoreRelocation.relocate(store, operations: operations)

        #expect(Self.deferralKind(result) == .unsupported)
        #expect(Self.deferralMessage(result) == "journal mode delete")
        #expect(result.resolvedURL == store.groupURL)
        #expect(operations.mutations.isEmpty)
        #expect(try Fixture.tree(at: fixture.groupDirectory) == groupTree)
    }

    @Test("Directories on different devices defer with the source intact")
    func deviceMismatchIsUnsupported() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.location()
        _ = try writeSourceReadyToMove(fixture, store: store)
        let groupPackage = try Fixture.packageEntries(at: fixture.groupDirectory)
        let appDevice = try #require(try DefaultModelStoreFileOperations().status(at: fixture.appDirectory)).deviceNumber
        let operations = Faults()
        operations.answerStatus(.deviceNumber(appDevice &+ 1), for: fixture.appDirectory)

        let result = ModelStoreRelocation.relocate(store, operations: operations)

        #expect(Self.deferralKind(result) == .unsupported)
        #expect(Self.deferralMessage(result).contains("device numbers differ"))
        #expect(result.resolvedURL == store.groupURL)
        #expect(!operations.mutations.contains { $0.method == .rename })
        #expect(try Fixture.packageEntries(at: fixture.groupDirectory) == groupPackage)
        #expect(ModelStoreRelocation.relocate(store).outcome == .moved)
    }

    enum UnusableSchema: CaseIterable, Sendable {
        case noTables
        case noMetadataTable
        case noMetadataRow

        var sql: String {
            switch self {
            case .noTables:
                "PRAGMA journal_mode = WAL;"
            case .noMetadataTable:
                "PRAGMA journal_mode = WAL; CREATE TABLE ZITEM (Z_PK INTEGER PRIMARY KEY, ZNAME VARCHAR);"
            case .noMetadataRow:
                "PRAGMA journal_mode = WAL; CREATE TABLE Z_METADATA (Z_VERSION INTEGER PRIMARY KEY, Z_UUID VARCHAR, Z_PLIST BLOB);"
            }
        }
    }

    @Test("A group store with no table or no Z_METADATA row is invalid and stays authoritative", arguments: UnusableSchema.allCases)
    func storeWithoutAUsableSchemaIsInvalid(_ schema: UnusableSchema) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.location()
        try Fixture.writeStore(at: store.appURL, uuid: UUID().uuidString, rows: ["app"])
        try Fixture.execute(schema.sql, at: store.groupURL)
        let appTree = try Fixture.tree(at: fixture.appDirectory)
        let operations = Faults()

        let result = ModelStoreRelocation.relocate(store, operations: operations)

        #expect(Self.deferralKind(result) == .invalid)
        #expect(result.storeUUID == nil)
        #expect(result.resolvedURL == store.groupURL)
        #expect(operations.mutations.isEmpty)
        #expect(try Fixture.tree(at: fixture.appDirectory) == appTree)
    }

    // MARK: - Unforeseen entries

    enum UnforeseenEntry: CaseIterable, Sendable {
        case backupFile
        case assetsDirectoryAsAFile

        var name: String {
            switch self {
            case .backupFile: "SyncedUserData.store.bak"
            case .assetsDirectoryAsAFile: "SyncedUserData_ckAssets"
            }
        }
    }

    @Test("An unforeseen entry beside the group store defers and nothing is deleted", arguments: UnforeseenEntry.allCases)
    func unforeseenEntryDefers(_ entry: UnforeseenEntry) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.location()
        try Fixture.writeStore(at: store.groupURL, uuid: UUID().uuidString, rows: Self.groupRows)
        try Data("unforeseen".utf8).write(to: fixture.groupDirectory.appending(path: entry.name))
        let groupPackage = try Fixture.packageEntries(at: fixture.groupDirectory)
        let operations = Faults()

        let result = ModelStoreRelocation.relocate(store, operations: operations)

        #expect(Self.deferralKind(result) == .unsupported)
        #expect(Self.deferralMessage(result).contains(entry.name))
        #expect(result.resolvedURL == store.groupURL)
        #expect(operations.mutations.isEmpty)
        #expect(try Fixture.packageEntries(at: fixture.groupDirectory) == groupPackage)
    }

    // MARK: - Layout and result

    @Test("One store moving while the other defers leaves one resolved URL in each container")
    func oneStoreMovesWhileTheOtherDefers() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let synced = fixture.location(Fixture.syncedName)
        let local = fixture.location(Fixture.localName)
        try Fixture.writeStore(at: synced.groupURL, uuid: UUID().uuidString, rows: Self.groupRows)
        try UnusableGroupStore.notSQLite.contents.write(to: local.groupURL)

        let (layout, results) = ModelStoreRelocation.relocate(ModelStoreLayout(synced: synced, local: local))

        #expect(results.map(\.configurationName) == [Fixture.syncedName, Fixture.localName])
        #expect(results.first?.outcome == .moved)
        #expect(Self.deferralKind(try #require(results.last)) == .inaccessible)
        #expect(layout.synced.resolvedURL == synced.appURL)
        #expect(layout.local.resolvedURL == local.groupURL)
        #expect(layout.localStoreURL == local.groupURL)
        #expect(layout.synced.groupURL == synced.groupURL && layout.synced.appURL == synced.appURL)
        #expect(layout.local.groupURL == local.groupURL && layout.local.appURL == local.appURL)
    }

    @Test("The result carries the store's Z_UUID, its -wal size before the checkpoint and the companion names")
    func resultReportsTheSource() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.location()
        let uuid = UUID().uuidString
        let walSize = try fixture.writeStoreWithRowsInTheLog(at: store.groupURL, uuid: uuid, rows: Self.groupRows)
        try Fixture.writeCompanions(in: fixture.groupDirectory, seed: "group")

        let result = ModelStoreRelocation.relocate(store)

        #expect(result.outcome == .moved)
        #expect(result.storeUUID == uuid)
        #expect(result.walSize == walSize)
        #expect(result.companions == [Self.support, Self.assets])
    }

    // MARK: - Fixtures

    private static let groupRows = ["group-1", "group-2", "group-3"]

    /// A group store at rest with both companions, beside a stale app store
    /// whose companion holds different bytes and one file the group lacks.
    /// Returns the group store's UUID.
    private func writeSourceReadyToMove(_ fixture: Fixture, store: ModelStoreLocation) throws -> String {
        let uuid = UUID().uuidString
        try Fixture.writeStore(at: store.groupURL, uuid: uuid, rows: Self.groupRows)
        try Fixture.writeCompanions(in: fixture.groupDirectory, seed: "group")
        try Fixture.writeStore(at: store.appURL, uuid: UUID().uuidString, rows: ["stale"])
        try Fixture.writeCompanions(in: fixture.appDirectory, seed: "stale")
        try Data("stale only".utf8).write(to: fixture.appDirectory.appending(path: "\(Self.support)/_EXTERNAL_DATA/stale-only"))
        return uuid
    }

    /// What a kill after the commit leaves beside the group URL.
    private func writeGroupLeftovers(_ fixture: Fixture, store: ModelStoreLocation) throws {
        try Data().write(to: Fixture.sidecar(store.groupURL, "-wal"))
        try Data(repeating: 0, count: 32_768).write(to: Fixture.sidecar(store.groupURL, "-shm"))
        try Fixture.writeCompanions(in: fixture.groupDirectory, seed: "leftover")
    }

    /// The group's package without its `-wal` sits in the app directory, and
    /// nothing of the package, `-shm` included, is left in the group.
    private func expectCleanEndState(_ fixture: Fixture, groupPackageBeforeTheRun: [String: Fixture.Entry]) throws {
        #expect(try Fixture.packageEntries(at: fixture.appDirectory) == Self.cleanAppPackage(from: groupPackageBeforeTheRun))
        #expect(try Fixture.packageEntries(at: fixture.groupDirectory).isEmpty)
        #expect(!Fixture.exists(fixture.groupDirectory.appending(path: "SyncedUserData.store-shm")))
    }

    private static func cleanAppPackage(from groupPackage: [String: Fixture.Entry]) -> [String: Fixture.Entry] {
        groupPackage.filter { $0.key != "SyncedUserData.store-wal" }
    }

    private static func fileCount(_ tree: [String: Fixture.Entry]) -> Int {
        tree.values.count(where: { $0 != .directory })
    }

    private static func deferralKind(_ result: ModelStoreRelocationResult) -> DeferralKind? {
        guard case .deferred(let deferral) = result.outcome else {
            return nil
        }
        return switch deferral {
        case .invalid: .invalid
        case .inaccessible: .inaccessible
        case .unsupported: .unsupported
        case .interrupted(let step, _): .interrupted(step)
        }
    }

    private static func deferralMessage(_ result: ModelStoreRelocationResult) -> String {
        guard case .deferred(let deferral) = result.outcome else {
            return ""
        }
        return switch deferral {
        case .invalid(let message), .inaccessible(let message), .unsupported(let message), .interrupted(_, let message):
            message
        }
    }
}
