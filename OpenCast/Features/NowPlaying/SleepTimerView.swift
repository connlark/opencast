import OpenCastPlayback
import SwiftUI

struct SleepTimerView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(SleepTimerOption.canonical) { option in
                Button(option.title) {
                    appModel.playback.setSleepTimer(mode: option.mode)
                    dismiss()
                }
                .disabled(option.isEndOfEpisode && appModel.playback.duration == nil)
            }
            .navigationTitle("Sleep Timer")
        }
    }
}
