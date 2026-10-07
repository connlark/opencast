import SwiftUI

struct SettingsAboutShareRow: View {
    var body: some View {
        ShareLink(
            item: OpenCastConstants.appStoreURL,
            subject: Text("opencast"),
            message: Text("opencast: podcast player. skip ads. open source.")
        ) {
            Label("Share opencast", systemImage: "square.and.arrow.up")
                .foregroundStyle(Color.primary)
        }
        .accessibilityIdentifier("Settings Row Share opencast")
    }
}
