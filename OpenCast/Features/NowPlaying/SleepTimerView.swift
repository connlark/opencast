import OpenCastPlayback
import SwiftUI

struct SleepTimerView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(SleepTimerOption.canonical) { option in
                Button(option.title) {
                    appModel.playback.setSleepTimer(duration: option.duration)
                    dismiss()
                }
            }
            .navigationTitle("Sleep Timer")
        }
    }
}
