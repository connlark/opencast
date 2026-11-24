import SwiftUI

struct PodcastInLibraryLabel: View {
    var body: some View {
        Label {
            Text("In Library")
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
