import OpenCastPlayback
import SwiftUI

struct VoiceBoostDiagnosticsSnapshotTaskModifier: ViewModifier {
    let diagnostics: VoiceBoostAudioTapDiagnostics
    @Binding var snapshot: VoiceBoostAudioTapDiagnosticsSnapshot

    func body(content: Content) -> some View {
        content.task {
            await observeSnapshots()
        }
    }

    private func observeSnapshots() async {
        while !Task.isCancelled {
            let nextSnapshot = diagnostics.snapshot
            if nextSnapshot != snapshot {
                snapshot = nextSnapshot
            }

            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }
}

extension View {
    func voiceBoostDiagnosticsSnapshotTask(
        diagnostics: VoiceBoostAudioTapDiagnostics,
        snapshot: Binding<VoiceBoostAudioTapDiagnosticsSnapshot>
    ) -> some View {
        modifier(VoiceBoostDiagnosticsSnapshotTaskModifier(
            diagnostics: diagnostics,
            snapshot: snapshot
        ))
    }
}
