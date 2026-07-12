import SwiftUI

/// Zero-sized view that owns the transcript screen's playback observation:
/// only this view re-evaluates on the 1 Hz position tick, keeping the
/// segment list's body out of the per-tick render path.
struct TranscriptPlaybackObserver: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let onPositionTick: () -> Void
    let onStateChange: () -> Void
    let onProgressBoundary: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: appModel.playback.position) { _, _ in
                onPositionTick()
            }
            .onChange(of: appModel.playback.state) { _, _ in
                onStateChange()
            }
            .onChange(of: appModel.playback.progressBoundaryID) { _, _ in
                onProgressBoundary()
            }
    }
}
