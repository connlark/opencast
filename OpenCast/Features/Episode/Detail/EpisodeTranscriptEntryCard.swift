import SwiftUI

/// Entry point into the lyrics-style transcript screen, previewing the first
/// lines of the transcript. The snippet is loaded by the parent in `.task`.
struct EpisodeTranscriptEntryCard: View {
    let episodeID: String
    let snippet: String?

    var body: some View {
        NavigationLink(value: AppRoute.episodeTranscript(id: episodeID)) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Transcript", systemImage: "text.quote")
                    .font(.headline)

                if let snippet {
                    Text(snippet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 4) {
                    Text("Read Transcript")
                    Image(systemName: "chevron.right")
                }
                .font(.subheadline)
                .foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .contentShape(.rect(cornerRadius: 26))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        .accessibilityIdentifier("Read Transcript")
    }
}

#Preview("Dark") {
    NavigationStack {
        EpisodeTranscriptEntryCard(
            episodeID: "preview",
            snippet: "Welcome back to the show. Today we're tracing a cache-coherency bug that only appears on Tuesdays, and…"
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Light") {
    NavigationStack {
        EpisodeTranscriptEntryCard(episodeID: "preview", snippet: nil)
            .padding()
    }
    .preferredColorScheme(.light)
}
