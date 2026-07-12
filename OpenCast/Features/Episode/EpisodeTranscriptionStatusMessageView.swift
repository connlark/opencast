import SwiftUI

struct EpisodeTranscriptionStatusMessageView: View {
    let title: String
    let message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message ?? "Try again while the app remains in the foreground.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
