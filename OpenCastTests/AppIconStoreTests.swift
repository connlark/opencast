import Testing
@testable import OpenCast

@MainActor
@Suite("App icon store")
struct AppIconStoreTests {
    @Test("Load reads the stored alternate icon name")
    func loadReadsStoredName() {
        let application = AlternateIconApplyingSpy(alternateIconName: "AppIconSunset")
        let store = AppIconStore(application: application)

        store.load()

        #expect(store.selection == .sunset)
        #expect(store.isSupported)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("Selecting applies the name and updates the selection")
    func selectAppliesNameAndUpdatesSelection() async {
        let application = AlternateIconApplyingSpy(alternateIconName: nil)
        let store = AppIconStore(application: application)
        store.load()

        await store.select(.violet)
        #expect(store.selection == .violet)
        #expect(application.appliedNames == ["AppIconViolet"])
        #expect(store.lastErrorMessage == nil)

        await store.select(.primary)
        #expect(store.selection == .primary)
        #expect(application.appliedNames == ["AppIconViolet", nil])
        #expect(!store.isApplying)
    }

    @Test("A failed change rolls back and records the error")
    func failedChangeRollsBack() async {
        let application = AlternateIconApplyingSpy(alternateIconName: nil, error: SpyError.refused)
        let store = AppIconStore(application: application)
        store.load()

        await store.select(.fern)

        #expect(store.selection == .primary)
        #expect(store.lastErrorMessage?.hasPrefix("Unable to change the app icon") == true)
        #expect(application.appliedNames.isEmpty)

        store.clearLastError()
        #expect(store.lastErrorMessage == nil)
    }
}

private enum SpyError: Error {
    case refused
}

@MainActor
private final class AlternateIconApplyingSpy: AlternateIconApplying {
    let supportsAlternateIcons = true
    private(set) var alternateIconName: String?
    private(set) var appliedNames: [String?] = []
    private let error: (any Error)?

    init(alternateIconName: String?, error: (any Error)? = nil) {
        self.alternateIconName = alternateIconName
        self.error = error
    }

    func setAlternateIconName(_ name: String?) async throws {
        if let error {
            throw error
        }
        appliedNames.append(name)
        alternateIconName = name
    }
}
