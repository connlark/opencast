import OpenCastCore
import SwiftUI

struct NowPlayingChapterBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = 36
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 14

    let chapters: PlaybackChapterList
    let position: TimeInterval
    let onSkipToPrevious: () -> Void
    let onSkipToNext: () -> Void
    let onShowChapters: () -> Void

    var body: some View {
        let current = chapters.chapter(at: position)
        let previous = chapters.previousChapter(before: position)
        let next = chapters.nextChapter(after: position)

        HStack(spacing: 12) {
            chapterButton(
                title: "Previous Chapter",
                systemImage: "backward.end.fill",
                target: previous,
                action: onSkipToPrevious
            )

            Button(action: onShowChapters) {
                VStack(spacing: 2) {
                    Text(current?.title ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                    if let current, let ordinal = chapters.ordinal(of: current) {
                        Text("Chapter \(ordinal) of \(chapters.chapters.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(currentChapterAccessibilityLabel(current))
            .accessibilityHint("Shows the chapter list")
            .accessibilityIdentifier("Now Playing Current Chapter")

            chapterButton(
                title: "Next Chapter",
                systemImage: "forward.end.fill",
                target: next,
                action: onSkipToNext
            )
        }
        .animation(.easeOut(duration: 0.2), value: current?.id)
    }

    private func chapterButton(
        title: String,
        systemImage: String,
        target: EpisodeChapter?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: resolvedIconSize, height: resolvedIconSize)
            }
            .labelStyle(.iconOnly)
            .frame(width: resolvedButtonSize, height: resolvedButtonSize)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(target == nil)
        .opacity(target == nil ? 0.4 : 1)
        .accessibilityLabel(title)
        .accessibilityValue(target?.title ?? "")
    }

    private var resolvedButtonSize: CGFloat {
        buttonSize.clamped(to: 32...48)
    }

    private var resolvedIconSize: CGFloat {
        iconSize.clamped(to: 12...20)
    }

    private func currentChapterAccessibilityLabel(_ chapter: EpisodeChapter?) -> String {
        guard let chapter, let ordinal = chapters.ordinal(of: chapter) else {
            return "No chapter playing"
        }
        return "Chapter \(ordinal) of \(chapters.chapters.count), \(chapter.title)"
    }
}

#Preview {
    let list = PlaybackChapterList(
        chapters: [
            EpisodeChapter(id: 0, title: "Pre-show", startTime: 0, endTime: 132),
            EpisodeChapter(id: 1, title: "Donate to St. Jude", startTime: 132, endTime: 461),
            EpisodeChapter(id: 2, title: "John’s iPhone 18 Pro", startTime: 461, endTime: 1262),
        ],
        source: .embedded
    )
    VStack(spacing: 24) {
        NowPlayingChapterBar(chapters: list, position: 10, onSkipToPrevious: {}, onSkipToNext: {}, onShowChapters: {})
        NowPlayingChapterBar(chapters: list, position: 500, onSkipToPrevious: {}, onSkipToNext: {}, onShowChapters: {})
    }
    .padding()
}
