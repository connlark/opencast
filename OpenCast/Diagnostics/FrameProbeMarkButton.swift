#if DEBUG || OPENCAST_PERFORMANCE_PROBES
import SwiftUI

struct FrameProbeMarkButton: View {
    var body: some View {
        Button("Probe Mark", action: mark)
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
            .background(.orange.opacity(0.35), in: .circle)
            .accessibilityIdentifier("Probe Mark")
    }

    private func mark() {
        if CommandLine.arguments.contains("--opencast-frame-probe-window") {
            NowPlayingFramePacingProbe.shared.toggleMeasurementWindow()
        } else {
            nowPlayingProbeMark("probe-window")
        }
    }
}
#endif
