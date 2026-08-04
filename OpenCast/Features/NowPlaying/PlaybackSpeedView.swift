import OpenCastPlayback
import SwiftUI

struct PlaybackSpeedView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List(PlaybackRateSteps.steps, id: \.self) { speed in
                Button {
                    select(speed)
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
            // Alert has no item overload for a non-Identifiable String.
            .alert(
                "Couldn’t Change Speed",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                ),
                presenting: errorMessage
            ) { _ in
            } message: { message in
                Text(message)
            }
        }
    }

    private func select(_ speed: Float) {
        if appModel.setPlaybackRate(speed, modelContext: modelContext) {
            dismiss()
        } else {
            errorMessage = appModel.playbackSettings.lastErrorMessage
                ?? "Playback speed could not be saved."
            appModel.playbackSettings.clearLastError()
        }
    }
}
