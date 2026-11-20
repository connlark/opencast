import SwiftUI

/// Zero-sized, so only this view re-evaluates on the 1 Hz position tick, not the segment list.
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
