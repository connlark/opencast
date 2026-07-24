#if DEBUG
import SwiftUI

struct NowPlayingSoundLabAdFreePassBackgroundProbeControl: View {
    let onRun: () -> Void

    var body: some View {
        Button(action: onRun) {
            Label("BG Probe", systemImage: "timer")
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("Now Playing Ad-Free Pass Background Probe")
    }
}
#endif
