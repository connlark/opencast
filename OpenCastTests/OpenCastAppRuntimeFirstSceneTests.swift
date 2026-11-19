import SwiftData
import Testing
@testable import OpenCast

/// What the runtime reads before the first scene exists, ahead of the
/// launch's settings load in the root view: the Up Next Tab switch, which
/// the first tab bar follows (D9).
@MainActor
@Suite("Before the first scene")
struct OpenCastAppRuntimeFirstSceneTests {
    @Test("With the switch stored on, the bootstrap has it on before any scene and before the launch's load")
    func readsTheUpNextTabSwitch() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        try LocalPreferenceRecord.upsert(
            key: AppearanceSettingsStore.showsUpNextTabPreferenceKey,
            value: "true",
            modelContext: context
        )
        try context.save()
        let appModel = makeAppModel()
        #expect(!appModel.appearanceSettings.showsUpNextTab)

        OpenCastAppRuntime.prepareFirstScene(appModel, modelContainer: container)

        #expect(appModel.appearanceSettings.showsUpNextTab)
    }

    @Test("With nothing stored, the bootstrap leaves the switch off")
    func leavesTheSwitchOffWhenNothingIsStored() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let appModel = makeAppModel()

        OpenCastAppRuntime.prepareFirstScene(appModel, modelContainer: container)

        #expect(!appModel.appearanceSettings.showsUpNextTab)
    }

    private func makeAppModel() -> OpenCastAppModel {
        OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            allowsAutomaticFeedRefresh: false
        )
    }
}
