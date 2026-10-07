import SwiftUI

struct SettingsAboutLinksSection: View {
    var body: some View {
        Section {
            SettingsExternalLinkRow(title: "Website", systemImage: "globe", destination: OpenCastConstants.websiteURL)
            SettingsAboutRateRow()
            SettingsAboutShareRow()
        } footer: {
            Text("opencast is open source under the MIT license.")
        }
    }
}
