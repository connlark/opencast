import SwiftUI

struct PlaybackSpeedView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    private let speeds: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        NavigationStack {
            List(speeds, id: \.self) { speed in
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
        }
    }
}
