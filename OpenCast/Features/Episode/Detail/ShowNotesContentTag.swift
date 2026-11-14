import SwiftUI

/// "From the show notes" marker for chapters read out of the episode's
/// description. These times are the publisher's text, not markers in the
/// audio itself, so they can sit a little off when ads are inserted into
/// the episode; the tag tells the listener where they came from.
struct ShowNotesContentTag: View {
    static let title = "From the show notes"

    var body: some View {
        Label(Self.title, systemImage: "text.alignleft")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
