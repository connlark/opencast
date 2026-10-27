import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Store relocation SwiftData round trip")
struct ModelStoreRelocationRoundTripTests {
    private static let configurationName = OpenCastModelContainerFactory.syncedConfigurationName
    private static let schema = Schema([ModelStoreRoundTripRecord.self, ModelStoreRoundTripPayloadRecord.self])

    @Test("Rows and an external-storage payload saved at the group URL read back through SwiftData at the app URL")
    func rowsAndExternalPayloadSurviveTheMove() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ModelStoreRelocationRoundTripTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let groupURL = root.appending(path: "group/Library/Application Support/\(Self.configurationName).store")
        let appURL = root.appending(path: "app/Library/Application Support/\(Self.configurationName).store")
        try FileManager.default.createDirectory(at: groupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dedupeUUIDs = (0..<3).map { _ in UUID().uuidString }.sorted()
        let payload = Data((0..<(384 * 1024)).map { _ in UInt8.random(in: .min ... .max) })

        try autoreleasepool {
            let context = ModelContext(try Self.container(at: groupURL))
            for dedupeUUID in dedupeUUIDs {
                context.insert(ModelStoreRoundTripRecord(dedupeUUID: dedupeUUID))
            }
            context.insert(ModelStoreRoundTripPayloadRecord(dedupeUUID: "payload", payload: payload))
            try context.save()
        }
        let externalData = groupURL.deletingLastPathComponent()
            .appending(path: ".\(Self.configurationName)_SUPPORT/_EXTERNAL_DATA", directoryHint: .isDirectory)
        try #require(
            try !FileManager.default.contentsOfDirectory(atPath: externalData.path(percentEncoded: false)).isEmpty,
            "the payload must sit in the group store's _EXTERNAL_DATA before the move"
        )

        let result = ModelStoreRelocation.relocate(
            ModelStoreLocation(
                configurationName: Self.configurationName,
                groupURL: groupURL,
                appURL: appURL,
                resolvedURL: groupURL
            )
        )

        try #require(result.outcome == .moved)
        #expect(result.resolvedURL == appURL)
        #expect(!FileManager.default.fileExists(atPath: groupURL.path(percentEncoded: false)))
        let context = ModelContext(try Self.container(at: result.resolvedURL))
        let records = try context.fetch(
            FetchDescriptor<ModelStoreRoundTripRecord>(sortBy: [SortDescriptor(\.dedupeUUID)])
        )
        #expect(records.map(\.dedupeUUID) == dedupeUUIDs)
        let payloads = try context.fetch(FetchDescriptor<ModelStoreRoundTripPayloadRecord>())
        #expect(payloads.map(\.dedupeUUID) == ["payload"])
        #expect(payloads.first?.payload == payload)
    }

    private static func container(at url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(configurationName, schema: schema, url: url, cloudKitDatabase: .none)]
        )
    }
}
