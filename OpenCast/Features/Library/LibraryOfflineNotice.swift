import SwiftUI

/// Shown after a refresh pass the device could not put on the network; the
/// rows keep their last real refresh status underneath.
struct LibraryOfflineNotice: View {
    var body: some View {
        Label("Offline — feeds will refresh when you're back online", systemImage: "wifi.slash")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("Library Offline Notice")
    }
}
