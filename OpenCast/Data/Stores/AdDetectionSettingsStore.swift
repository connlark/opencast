import Observation
import SwiftData

/// Device-local. A nil mode is unset: the next manual Detect Ads tap asks.
@Observable
final class AdDetectionSettingsStore {
    static let modePreferenceKey = "adDetection.mode"

    private(set) var mode: AdDetectionMode?
    private(set) var lastErrorMessage: String?

    func load(modelContext: ModelContext) {
        do {
            mode = try LocalPreferenceRecord.preference(
                forKey: Self.modePreferenceKey,
                modelContext: modelContext
            ).flatMap { AdDetectionMode(rawValue: $0.value) }
            lastErrorMessage = nil
        } catch {
            mode = nil
            lastErrorMessage = "Unable to load ad detection settings: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func setMode(_ mode: AdDetectionMode?, modelContext: ModelContext) -> Bool {
        let previousMode = self.mode
        self.mode = mode

        do {
            if let mode {
                try LocalPreferenceRecord.upsert(
                    key: Self.modePreferenceKey,
                    value: mode.rawValue,
                    modelContext: modelContext
                )
            } else {
                try LocalPreferenceRecord.deletePreferences(
                    forKey: Self.modePreferenceKey,
                    modelContext: modelContext
                )
            }
            try modelContext.save()
            lastErrorMessage = nil
            return true
        } catch {
            self.mode = previousMode
            lastErrorMessage = "Unable to update ad detection settings: \(error.localizedDescription)"
            return false
        }
    }
}
