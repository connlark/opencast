import SwiftUI

struct SettingsAboutSection: View {
    var body: some View {
        Section {
            Link(destination: OpenCastConstants.supportURL) {
                ExternalSettingsLinkRow(
                    title: "Support",
                    subtitle: "Help, bug reports, and contact details",
                    systemImage: "lifepreserver",
                    tint: .blue
                )
            }

            Link(destination: OpenCastConstants.privacyPolicyURL) {
                ExternalSettingsLinkRow(
                    title: "Privacy Policy",
                    subtitle: "How opencast handles listening data",
                    systemImage: "hand.raised",
                    tint: .teal
                )
            }

            Link(destination: OpenCastConstants.sourceCodeURL) {
                ExternalSettingsLinkRow(
                    title: "GitHub",
                    subtitle: "Source code and MIT license",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    tint: .indigo
                )
            }

            LabeledContent {
                Text(versionText)
            } label: {
                Label("Version", systemImage: "info.circle")
            }
        } header: {
            Text("About")
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        return switch (version, build) {
        case let (version?, build?):
            "\(version) (\(build))"
        case let (version?, nil):
            version
        case let (nil, build?):
            "Build \(build)"
        case (nil, nil):
            "Unavailable"
        }
    }
}
