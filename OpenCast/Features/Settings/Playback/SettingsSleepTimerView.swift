import SwiftData
import SwiftUI

/// The six sleep timer presets, reached from Settings › Playback and from
/// the sleep timer sheet's pencil.
struct SettingsSleepTimerView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        let presets = appModel.playbackSettings.sleepTimerPresets

        Form {
            Section {
                ForEach(presets.indices, id: \.self) { index in
                    SleepTimerPresetRow(
                        position: index + 1,
                        selection: presetBinding(at: index),
                        choices: choices(for: index, in: presets)
                    )
                }

                if let message = appModel.playbackSettings.lastErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Presets")
            } footer: {
                Text("The sleep timer lists these shortest first.")
            }
        }
        .settingsSubscreen(title: "Sleep Timer")
    }

    /// Every duration except those the other five slots hold, so the six
    /// stay distinct.
    private func choices(
        for index: Int,
        in presets: [SleepTimerPresetDuration]
    ) -> [SleepTimerPresetDuration] {
        var heldElsewhere = presets
        heldElsewhere.remove(at: index)
        return SleepTimerPresetDuration.allCases.filter { !heldElsewhere.contains($0) }
    }

    private func presetBinding(at index: Int) -> Binding<SleepTimerPresetDuration> {
        Binding {
            appModel.playbackSettings.sleepTimerPresets[index]
        } set: { duration in
            _ = appModel.setSleepTimerPreset(duration, at: index, modelContext: modelContext)
        }
    }
}
