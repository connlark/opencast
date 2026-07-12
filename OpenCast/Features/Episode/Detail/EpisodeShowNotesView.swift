import SwiftUI

/// Show notes rendered one paragraph block per `Text` in a lazy stack, so
/// arbitrarily long notes never exceed what a single text view can paint.
struct EpisodeShowNotesView: View {
    let blocks: [AttributedString]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            Text("Show Notes")
                .font(.headline)

            ForEach(blocks.indices, id: \.self) { index in
                Text(blocks[index])
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

#Preview("Dark") {
    ScrollView {
        EpisodeShowNotesView(
            blocks: HTMLAttributedText.attributedBlocks(
                from: """
                <p>This week we cover <b>speculative execution</b> with guest \
                <a href="https://example.com">Dr. Cache</a>.</p>
                <ul><li>Prefetchers gone wrong</li><li>The Tuesday bug</li></ul>
                <p>Call the show at (555) 123-4567.</p>
                """
            )
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Light") {
    ScrollView {
        EpisodeShowNotesView(
            blocks: HTMLAttributedText.attributedBlocks(
                from: "<p>Short notes with <em>emphasis</em> only.</p>"
            )
        )
        .padding()
    }
    .preferredColorScheme(.light)
}
