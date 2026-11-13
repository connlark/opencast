import SwiftUI

/// "From the publisher" marker for chapters the feed's own chapters document
/// supplies. The card's tag is the only visible difference between chapter
/// sources, so publisher rows name theirs just as generated rows do.
struct PublisherContentTag: View {
    var body: some View {
        Label("From the publisher", systemImage: "checkmark.seal")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
