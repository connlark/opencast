import OpenCastPlayback
import SwiftUI

struct SleepTimerView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    private let options: [SleepTimerOption] = [
        SleepTimerOption(title: "Off", duration: nil),
        SleepTimerOption(title: "15 Minutes", duration: 15 * 60),
        SleepTimerOption(title: "30 Minutes", duration: 30 * 60),
        SleepTimerOption(title: "45 Minutes", duration: 45 * 60),
        SleepTimerOption(title: "1 Hour", duration: 60 * 60)
    ]

    var body: some View {
        NavigationStack {
            List(options) { option in
                Button(option.title) {
                    appModel.playback.setSleepTimer(duration: option.duration)
                    dismiss()
                }
            }
            .navigationTitle("Sleep Timer")
        }
    }
}
