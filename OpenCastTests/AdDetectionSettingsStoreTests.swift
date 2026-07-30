import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Ad detection settings store")
struct AdDetectionSettingsStoreTests {
    @Test("Mode persists and reloads")
    func modePersistsAndReloads() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = AdDetectionSettingsStore()

        store.load(modelContext: context)
        #expect(store.mode == nil)
        #expect(store.setMode(.onDevice, modelContext: context))
        #expect(store.mode == .onDevice)
        #expect(store.lastErrorMessage == nil)

        let reloadedStore = AdDetectionSettingsStore()
        reloadedStore.load(modelContext: context)
        #expect(reloadedStore.mode == .onDevice)
    }

    @Test("A failed save reverts the mode and surfaces the error")
    func failedSaveRevertsModeAndSurfacesError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AdDetectionSettingsStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appending(path: "read-only.store")
        // Create the store writable first; a read-only configuration cannot
        // build the store file itself.
        do {
            let writableConfiguration = ModelConfiguration(
                schema: OpenCastModelContainerFactory.localSchema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            _ = try ModelContainer(
                for: OpenCastModelContainerFactory.localSchema,
                configurations: [writableConfiguration]
            )
        }
        let readOnlyConfiguration = ModelConfiguration(
            schema: OpenCastModelContainerFactory.localSchema,
            url: storeURL,
            allowsSave: false,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: OpenCastModelContainerFactory.localSchema,
            configurations: [readOnlyConfiguration]
        )
        let context = ModelContext(container)
        let store = AdDetectionSettingsStore()
        store.load(modelContext: context)

        let didSave = store.setMode(.cloud, modelContext: context)

        #expect(!didSave)
        #expect(store.mode == nil)
        #expect(store.lastErrorMessage != nil)
    }
}
