#if DEBUG
import SwiftUI

struct DiagnosticsDeveloperSection: View {
    @Environment(OpenCastAppModel.self) private var appModel

    @State private var remoteTranscriptionDevEnabled = RemoteTranscriptionDevFlag.isEnabled

    var body: some View {
        @Bindable var appModel = appModel

        Section("Developer") {
            Button(action: runOnboarding) {
                Label("Run Onboarding", systemImage: "sparkles.rectangle.stack")
            }

            if AdFreePassBackgroundProbe.isUserInterfaceEnabled {
                Button(action: runAdFreePassBackgroundProbe) {
                    Label("Ad-Free BG Probe", systemImage: "timer")
                }
                .accessibilityIdentifier("Settings Ad-Free Pass Background Probe")
            }

            Toggle(isOn: $appModel.replacesNowPlayingArtworkWithPlaybackDiagnostics) {
                Label("Playback Debug Artwork", systemImage: "terminal")
            }

            Toggle(isOn: remoteTranscriptionDevBinding) {
                Label("Remote Transcription (Dev)", systemImage: "cloud")
            }

            if remoteTranscriptionDevEnabled,
               let balance = appModel.remoteTranscription.store.balance {
                LabeledContent("Remote Dev Balance") {
                    Text(
                        Duration.seconds(balance.availableSeconds)
                            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
                    )
                }
            }
        }
    }

    // The flag lives in UserDefaults behind a static gate, so the alert-style
    // manual Binding exception applies: local @State mirrors it for SwiftUI.
    private var remoteTranscriptionDevBinding: Binding<Bool> {
        Binding(
            get: { remoteTranscriptionDevEnabled },
            set: { enabled in
                remoteTranscriptionDevEnabled = enabled
                RemoteTranscriptionDevFlag.setEnabled(enabled)
            }
        )
    }

    private func runOnboarding() {
        appModel.requestOnboardingPresentation()
    }

    private func runAdFreePassBackgroundProbe() {
        AdFreePassBackgroundProbe.startFromUserAction()
    }
}
#endif
