import SwiftUI

struct SettingsDebugSection: View {
    @Environment(OpenCastAppModel.self) private var appModel

    var body: some View {
        Section {
            NavigationLink {
                SettingsDiagnosticsView()
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }

            Button(action: runOnboarding) {
                Label("Run Onboarding", systemImage: "sparkles.rectangle.stack")
            }
        } header: {
            Text("Debug")
        }
    }

    private func runOnboarding() {
        appModel.requestOnboardingPresentation()
    }
}
