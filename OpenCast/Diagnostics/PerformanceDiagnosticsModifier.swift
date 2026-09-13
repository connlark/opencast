import OpenCastPlayback
import SwiftUI

struct PerformanceDiagnosticsModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase, initial: true) { _, phase in
                PerformanceStateReporter.shared.transition(.scene, to: phase == .background ? "background" : "foreground")
            }
            .onChange(of: appModel.playback.state, initial: true) { _, state in
                let label = switch state {
                case .idle: "absent"
                case .paused, .failed: "paused"
                case .loading, .buffering: "buffering"
                case .playing: "playing"
                }
                PerformanceStateReporter.shared.transition(.playback, to: label)
            }
            .onChange(of: appModel.isNowPlayingPresented, initial: true) { _, presented in
                if !presented { PerformanceStateReporter.shared.transition(.nowPlaying, to: "hidden") }
            }
            .onChange(of: transcriptionState, initial: true) { _, state in
                PerformanceStateReporter.shared.transition(.transcription, to: state)
            }
            .onChange(of: appModel.transcriptions.diagnosticComputeClass, initial: true) { _, value in
                PerformanceStateReporter.shared.transition(.compute, to: value)
            }
            .onChange(of: appModel.library.state, initial: true) { _, state in
                let label = switch state {
                case .loading: "loading"
                case .refreshing: "refreshing"
                case .idle, .failed: "idle"
                }
                PerformanceStateReporter.shared.transition(.feed, to: label)
            }
    }

    private var transcriptionState: String {
        if appModel.transcriptions.activeEpisodeID != nil { return "on-device" }
        if appModel.remoteTranscription.store.phase?.isTerminal == false { return "remote" }
        return "idle"
    }
}
