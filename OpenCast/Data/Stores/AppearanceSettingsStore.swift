import Foundation
import Observation
import SwiftData

/// Device-local appearance preferences. Every load and save runs in its own
/// short-lived context, as in `LibraryDisplaySettingsStore`: a failed save is
/// discarded with that context instead of lingering as a dirty row that a
/// later unrelated save would commit. Published values change only after a
/// save succeeds.
@Observable
final class AppearanceSettingsStore {
    private static let modeKey = "appearance.mode"
    private static let minimizesTabBarOnScrollKey = "appearance.minimizesTabBarOnScroll"
    static let showsUpNextTabPreferenceKey = "appearance.showsUpNextTab"

    private(set) var mode = AppAppearanceMode.system
    private(set) var minimizesTabBarOnScroll = false
    private(set) var showsUpNextTab = false
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let save: (ModelContext) throws -> Void

    /// `save` is the test seam for preference saves.
    init(save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.save = save
    }

    func load(modelContext: ModelContext) {
        let context = ModelContext(modelContext.container)
        do {
            mode = try storedValue(forKey: Self.modeKey, context: context)
                .flatMap(AppAppearanceMode.init(rawValue:)) ?? .system
            minimizesTabBarOnScroll = try storedValue(forKey: Self.minimizesTabBarOnScrollKey, context: context)
                .flatMap(Bool.init) ?? false
            publishShowsUpNextTab(try storedShowsUpNextTab(context: context))
            lastErrorMessage = nil
        } catch {
            mode = .system
            minimizesTabBarOnScroll = false
            publishShowsUpNextTab(false)
            lastErrorMessage = "Unable to load appearance settings: \(error.localizedDescription)"
        }
    }

    /// The Up Next Tab switch alone, read before the first frame
    /// (`OpenCastAppRuntime`) so the first tab bar is already the right one;
    /// the launch's `load` reads it again with the rest.
    func loadShowsUpNextTab(modelContext: ModelContext) {
        do {
            publishShowsUpNextTab(try storedShowsUpNextTab(context: ModelContext(modelContext.container)))
        } catch {
            lastErrorMessage = "Unable to load appearance settings: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func setMode(_ mode: AppAppearanceMode, modelContext: ModelContext) -> Bool {
        guard self.mode != mode else {
            return true
        }
        guard persist(
            mode.rawValue,
            forKey: Self.modeKey,
            modelContext: modelContext,
            failureDescription: "Unable to update appearance settings"
        ) else {
            return false
        }

        self.mode = mode
        return true
    }

    @discardableResult
    func setMinimizesTabBarOnScroll(_ minimizesTabBarOnScroll: Bool, modelContext: ModelContext) -> Bool {
        guard self.minimizesTabBarOnScroll != minimizesTabBarOnScroll else {
            return true
        }
        guard persist(
            String(minimizesTabBarOnScroll),
            forKey: Self.minimizesTabBarOnScrollKey,
            modelContext: modelContext,
            failureDescription: "Unable to update the tab bar setting"
        ) else {
            return false
        }

        self.minimizesTabBarOnScroll = minimizesTabBarOnScroll
        return true
    }

    @discardableResult
    func setShowsUpNextTab(_ showsUpNextTab: Bool, modelContext: ModelContext) -> Bool {
        guard self.showsUpNextTab != showsUpNextTab else {
            return true
        }
        guard persist(
            String(showsUpNextTab),
            forKey: Self.showsUpNextTabPreferenceKey,
            modelContext: modelContext,
            failureDescription: "Unable to update the tab bar setting"
        ) else {
            return false
        }

        self.showsUpNextTab = showsUpNextTab
        return true
    }

    func clearLastError() {
        lastErrorMessage = nil
    }

    private func persist(
        _ value: String,
        forKey key: String,
        modelContext: ModelContext,
        failureDescription: String
    ) -> Bool {
        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        do {
            try LocalPreferenceRecord.upsert(key: key, value: value, modelContext: context)
            try save(context)
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "\(failureDescription): \(error.localizedDescription)"
            return false
        }
    }

    private func storedShowsUpNextTab(context: ModelContext) throws -> Bool {
        try storedValue(forKey: Self.showsUpNextTabPreferenceKey, context: context).flatMap(Bool.init) ?? false
    }

    /// Writes only a change: the root view reads the switch to start each
    /// scene's tab set, and an unchanged write at the launch's `load` would
    /// cost every listener an update of it.
    private func publishShowsUpNextTab(_ showsUpNextTab: Bool) {
        if self.showsUpNextTab != showsUpNextTab {
            self.showsUpNextTab = showsUpNextTab
        }
    }

    private func storedValue(forKey key: String, context: ModelContext) throws -> String? {
        try LocalPreferenceRecord.preference(forKey: key, modelContext: context)?.value
    }
}
