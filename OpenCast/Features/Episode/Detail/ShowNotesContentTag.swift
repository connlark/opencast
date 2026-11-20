import SwiftUI

struct ShowNotesContentTag: View {
    static let title = "From the show notes"

    var body: some View {
        Label(Self.title, systemImage: "text.alignleft")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
