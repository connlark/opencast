#if DEBUG
import SwiftUI

/// Test-tappable mark source for the frame-pacing probe. Each tap records a
/// `probe-window` mark, letting UI tests bracket arbitrary workloads (scroll
/// runs, load scenarios) into flushed probe sessions. Mounted only while the
/// probe is enabled (`--opencast-frame-probe`), so the visible dot never ships
/// in normal use.
struct FrameProbeMarkButton: View {
    var body: some View {
        Button("Probe Mark", action: mark)
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
            .background(.orange.opacity(0.35), in: .circle)
            .accessibilityIdentifier("Probe Mark")
    }

    private func mark() {
        nowPlayingProbeMark("probe-window")
    }
}
#endif
