import SwiftData
import SwiftUI

struct SettingsAdSkippingView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        let settings = appModel.playbackSettings
        Form {
            Section {
                Toggle("Auto-Skip Promos & Ads", isOn: autoSkipBinding)

                NavigationLink(value: AppRoute.settings(.skipSound)) {
                    LabeledContent("Skip Sound", value: settings.autoSkipSound?.name ?? "None")
                }
                .disabled(!settings.isAutoSkipPromosAndAdsEnabled)
                .accessibilityIdentifier("ad-skipping-skip-sound-row")

                if let message = settings.lastErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text(footerText)
            }

            SettingsAdDetectionSection()
        }
        .settingsSubscreen(title: "Ad Skipping")
    }

    private var footerText: String {
        let autoSkip = "Skips detected promos and ads while an episode plays."
        return appModel.playbackSettings.autoSkipSound == nil
            ? autoSkip
            : "\(autoSkip) Plays when an ad is skipped while you are listening."
    }

    private var autoSkipBinding: Binding<Bool> {
        Binding {
            appModel.playbackSettings.isAutoSkipPromosAndAdsEnabled
        } set: { isEnabled in
            _ = appModel.setAutoSkipPromosAndAdsEnabled(isEnabled, modelContext: modelContext)
        }
    }
}
