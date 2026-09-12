import SwiftUI

struct SettingsHubHelpSection: View {
    var body: some View {
        Section("Help") {
            SettingsNavigationRow(title: "Help", systemImage: "questionmark.circle", route: .help)
            SettingsExternalLinkRow(
                title: "Support",
                systemImage: "lifepreserver",
                destination: OpenCastConstants.supportURL
            )
            SettingsExternalLinkRow(
                title: "Privacy Policy",
                systemImage: "hand.raised",
                destination: OpenCastConstants.privacyPolicyURL
            )
            SettingsExternalLinkRow(
                title: "Source Code",
                systemImage: "chevron.left.forwardslash.chevron.right",
                destination: OpenCastConstants.sourceCodeURL
            )
            SettingsNavigationRow(
                title: "About",
                systemImage: "info.circle",
                route: .about,
                value: OpenCastAppVersion.shortVersion
            )
        }
    }
}
