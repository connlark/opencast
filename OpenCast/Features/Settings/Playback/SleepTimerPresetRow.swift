import SwiftUI

struct SleepTimerPresetRow: View {
    let position: Int
    @Binding var selection: SleepTimerPresetDuration
    let choices: [SleepTimerPresetDuration]

    var body: some View {
        LabeledContent("Preset \(position)") {
            Picker("Preset \(position)", selection: $selection) {
                ForEach(choices) { duration in
                    Text(duration.title)
                        .tag(duration)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("sleep-timer-preset-\(position)")
        }
    }
}
