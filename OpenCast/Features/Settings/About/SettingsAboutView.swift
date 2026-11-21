import SwiftUI

struct SettingsAboutView: View {
    @State private var hero = SettingsAboutHeroModel()

    var body: some View {
        Form {
            SettingsAboutHeroSection(model: hero)

            Section {
                SettingsAboutVersionRow()
                SettingsExternalLinkRow(
                    title: "Changelog",
                    systemImage: "clock.arrow.circlepath",
                    destination: OpenCastConstants.changelogURL
                )
            }

            SettingsAboutLinksSection()
            SettingsSiriSection()
        }
        .settingsSubscreen(title: "About")
    }
}

#Preview("Light") {
    NavigationStack {
        SettingsAboutView()
    }
    .environment(OpenCastAppModel())
}

#Preview("Dark") {
    NavigationStack {
        SettingsAboutView()
    }
    .environment(OpenCastAppModel())
    .preferredColorScheme(.dark)
}

#Preview("AX5") {
    NavigationStack {
        SettingsAboutView()
    }
    .environment(OpenCastAppModel())
    .dynamicTypeSize(.accessibility5)
}
