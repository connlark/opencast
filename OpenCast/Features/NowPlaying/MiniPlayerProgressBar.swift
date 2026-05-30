import SwiftUI

struct MiniPlayerProgressBar: View {
    @Environment(OpenCastAppModel.self) private var appModel

    var body: some View {
        ProgressView(value: progress)
            .progressViewStyle(.linear)
            .tint(.accentColor)
            .frame(height: 2)
            .accessibilityHidden(true)
    }

    private var progress: Double {
        (appModel.playback.progress * 200).rounded() / 200
    }
}
