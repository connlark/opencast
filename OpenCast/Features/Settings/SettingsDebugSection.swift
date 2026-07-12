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
        } header: {
            Text("Debug")
        }
    }

    private func runOnboarding() {
        appModel.requestOnboardingPresentation()
    }

    #if DEBUG
    private func runAdFreePassBackgroundProbe() {
        AdFreePassBackgroundProbe.startFromUserAction()
    }
    #endif
}
