import SwiftUI

struct SettingsAboutView: View {
    @State private var hero = SettingsAboutHeroModel()

    var body: some View {
        Form {
            SettingsAboutHeroSection(model: hero)

            Section {
                SettingsAboutVersionRow()
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
