import SwiftUI

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
