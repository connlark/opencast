import Foundation
import Observation
import SwiftData

@Observable
final class AppearanceSettingsStore {
    private static let modeKey = "appearance.mode"

    private(set) var mode = AppAppearanceMode.system
    private(set) var lastErrorMessage: String?

    func load(modelContext: ModelContext) {
        do {
            mode = try storedMode(modelContext: modelContext)
            lastErrorMessage = nil
        } catch {
            mode = .system
            lastErrorMessage = "Unable to load appearance settings: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func setMode(_ mode: AppAppearanceMode, modelContext: ModelContext) -> Bool {
        guard self.mode != mode else {
            return true
        }

        let previousMode = self.mode
        self.mode = mode

        do {
            try LocalPreferenceRecord.upsert(
                key: Self.modeKey,
                value: mode.rawValue,
                modelContext: modelContext
            )
            try modelContext.save()
            lastErrorMessage = nil
            return true
        } catch {
            self.mode = previousMode
            lastErrorMessage = "Unable to update appearance settings: \(error.localizedDescription)"
            return false
        }
    }

    func clearLastError() {
        lastErrorMessage = nil
    }

    private func storedMode(modelContext: ModelContext) throws -> AppAppearanceMode {
        guard let rawValue = try LocalPreferenceRecord.preference(forKey: Self.modeKey, modelContext: modelContext)?.value,
              let mode = AppAppearanceMode(rawValue: rawValue)
        else {
            return .system
        }

        return mode
    }
}
