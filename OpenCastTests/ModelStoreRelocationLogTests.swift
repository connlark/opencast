import Foundation
import os
import Testing
@testable import OpenCast

@Suite("Store relocation log")
struct ModelStoreRelocationLogTests {
    private static let testLogger = Logger(subsystem: "com.connor.opencast", category: "StoreRelocationTests")
    private static let firstLaunch = Date(timeIntervalSince1970: 1_793_064_600)
    private static let secondLaunch = Date(timeIntervalSince1970: 1_793_065_500)

    private static let moved = ModelStoreRelocationResult(
        configurationName: "SyncedUserData",
        resolvedURL: URL(filePath: "/app/Library/Application Support/SyncedUserData.store"),
        outcome: .moved,
        storeUUID: "6F1C-UUID",
        walSize: 32_992,
        companions: [".SyncedUserData_SUPPORT", "SyncedUserData_ckAssets"],
        notes: []
    )
    private static let interrupted = ModelStoreRelocationResult(
        configurationName: "LocalDeviceData",
        resolvedURL: URL(filePath: "/group/Library/Application Support/LocalDeviceData.store"),
        outcome: .deferred(.interrupted(.copyCompanions, "No space left on device")),
        storeUUID: "0A2B-UUID",
        walSize: nil,
        companions: [],
        notes: ["first note", "second\nnote"]
    )
    private static let inPlace = ModelStoreRelocationResult(
        configurationName: "LocalDeviceData",
        resolvedURL: URL(filePath: "/app/Library/Application Support/LocalDeviceData.store"),
        outcome: .inPlace,
        storeUUID: nil,
        walSize: nil,
        companions: [],
        notes: []
    )

    @Test("Each store's line is appended under the launch's UTC stamp, creating the directory")
    func appendsStampedLines() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "Diagnostics/store-relocation.log")
        let log = ModelStoreRelocationLog(fileURL: fileURL, logger: Self.testLogger)

        log.record([Self.moved, Self.interrupted], at: Self.firstLaunch)
        log.record([Self.inPlace], at: Self.secondLaunch)

        #expect(try String(contentsOf: fileURL, encoding: .utf8) == """
            2026-10-27T01:30:00Z SyncedUserData moved; uuid 6F1C-UUID; wal 32992 bytes; \
            companions .SyncedUserData_SUPPORT, SyncedUserData_ckAssets; notes none; \
            opens /app/Library/Application Support/SyncedUserData.store
            2026-10-27T01:30:00Z LocalDeviceData deferred, interrupted at copyCompanions: No space left on device; \
            uuid 0A2B-UUID; wal unprobed; companions none; notes first note | second note; \
            opens /group/Library/Application Support/LocalDeviceData.store
            2026-10-27T01:45:00Z LocalDeviceData in place; uuid unread; wal unprobed; companions none; notes none; \
            opens /app/Library/Application Support/LocalDeviceData.store

            """)
    }

    @Test("Every deferral reason is named with its detail")
    func deferralReasonsAreNamed() {
        let lines = [
            ModelStoreRelocationResult.Outcome.deferred(.invalid("no Z_METADATA")),
            .deferred(.inaccessible("open failed: 23")),
            .deferred(.unsupported("journal_mode delete")),
            .ambiguous
        ].map { outcome in
            ModelStoreRelocationLog.line(
                for: ModelStoreRelocationResult(
                    configurationName: "SyncedUserData",
                    resolvedURL: URL(filePath: "/group/SyncedUserData.store"),
                    outcome: outcome,
                    storeUUID: nil,
                    walSize: nil,
                    companions: [],
                    notes: []
                )
            )
        }

        #expect(lines.map { $0.prefix { $0 != ";" } } == [
            "SyncedUserData deferred, invalid: no Z_METADATA",
            "SyncedUserData deferred, inaccessible: open failed: 23",
            "SyncedUserData deferred, unsupported: journal_mode delete",
            "SyncedUserData ambiguous"
        ])
    }

    @Test("A file over the cap is replaced by the lines being written")
    func overTheCapKeepsOnlyTheNewLines() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "Diagnostics/store-relocation.log")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: UInt8(ascii: "x"), count: 513).write(to: fileURL)
        let log = ModelStoreRelocationLog(fileURL: fileURL, maximumByteCount: 512, logger: Self.testLogger)

        log.record([Self.moved], at: Self.firstLaunch)

        #expect(
            try String(contentsOf: fileURL, encoding: .utf8)
                == "2026-10-27T01:30:00Z \(ModelStoreRelocationLog.line(for: Self.moved))\n"
        )
    }

    @Test("The production log is capped at 256 KiB in the app container's Diagnostics directory")
    func productionDefaults() {
        let log = ModelStoreRelocationLog()

        #expect(log.maximumByteCount == 256 * 1024)
        #expect(log.fileURL == URL.applicationSupportDirectory.appending(path: "Diagnostics/store-relocation.log"))
    }

    @Test("A file that cannot be written leaves the launch going and writes nothing")
    func unwritableFileIsNotThrown() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blockingFile = root.appending(path: "Diagnostics")
        try Data().write(to: blockingFile)
        let log = ModelStoreRelocationLog(
            fileURL: blockingFile.appending(path: "store-relocation.log"),
            logger: Self.testLogger
        )

        log.record([Self.moved], at: Self.firstLaunch)

        #expect(try Data(contentsOf: blockingFile).isEmpty)
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "ModelStoreRelocationLogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
