import SwiftUI

struct SettingsDebugSection: View {
    @Environment(OpenCastAppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        Section {
            NavigationLink {
                SettingsDiagnosticsView()
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }

            Button(action: runOnboarding) {
                Label("Run Onboarding", systemImage: "sparkles.rectangle.stack")
            }

            #if DEBUG
            if AdFreePassBackgroundProbe.isUserInterfaceEnabled {
                Button(action: runAdFreePassBackgroundProbe) {
                    Label("Ad-Free BG Probe", systemImage: "timer")
                }
                .accessibilityIdentifier("Settings Ad-Free Pass Background Probe")
            }
            #endif

            Toggle(isOn: $appModel.replacesNowPlayingArtworkWithPlaybackDiagnostics) {
                Label("Playback Debug Artwork", systemImage: "terminal")
            }

            #if DEBUG
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
            #endif
        } header: {
            Text("Debug")
        }
    }

    private func runOnboarding() {
        appModel.requestOnboardingPresentation()
    }

    #if DEBUG
    @State private var remoteTranscriptionDevEnabled = RemoteTranscriptionDevFlag.isEnabled

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

    private func runAdFreePassBackgroundProbe() {
        AdFreePassBackgroundProbe.startFromUserAction()
    }
    #endif
}
