import SwiftUI

/// Show notes rendered one paragraph block per `Text` in a lazy stack, so
/// arbitrarily long notes never exceed what a single text view can paint.
struct EpisodeShowNotesView: View {
    let blocks: [AttributedString]
    let onSelectTimestamp: (TimeInterval) -> Void

    var body: some View {
        let identifiedBlocks = EpisodeShowNotesBlock.identify(blocks)
        LazyVStack(alignment: .leading, spacing: 10) {
            Text("Show Notes")
                .font(.headline)

            ForEach(identifiedBlocks) { block in
                Text(block.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .environment(\.openURL, OpenURLAction(handler: openLink))
    }

    private func openLink(_ url: URL) -> OpenURLAction.Result {
        guard let seconds = ShowNotesTimestampLink.seconds(from: url) else {
            return .systemAction
        }
        onSelectTimestamp(seconds)
        return .handled
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
                <p>(00:02:16) Prefetchers gone wrong<br>8:39 – The Tuesday bug</p>
                <p>Call the show at (555) 123-4567.</p>
                """
            ),
            onSelectTimestamp: { _ in }
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
            ),
            onSelectTimestamp: { _ in }
        )
        .padding()
    }
    .preferredColorScheme(.light)
}
