import SwiftUI

struct PublisherContentTag: View {
    var body: some View {
        Label("From the publisher", systemImage: "checkmark.seal")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
