import OpenCastPlayback
import SwiftUI

struct PlaybackSpeedView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(PlaybackRateSteps.steps, id: \.self) { speed in
                Button {
                    appModel.playback.setRate(speed)
                    dismiss()
                } label: {
                    HStack {
                        Text(speed.formattedSpeed)
                        Spacer()
                        if appModel.playback.rate == speed {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            .navigationTitle("Speed")
            .sensoryFeedback(.selection, trigger: appModel.playback.rate)
        }
    }
}
