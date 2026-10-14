import OpenCastCore
import SwiftUI

/// Chapter list on episode detail: title + start time, tap seeks. Renders
/// chapters embedded in the audio file or a current generated analysis;
/// the tag tells them apart.
struct EpisodeChaptersCard: View {
    enum Source {
        case embedded
        case generated
    }

    let chapters: [EpisodeChapter]
    let source: Source
    let onSelectChapter: (EpisodeChapter) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Chapters", systemImage: "list.bullet")
                    .font(.headline)
                Spacer()
                if source == .generated {
                    GeneratedContentTag()
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(chapters) { chapter in
                    Button {
                        onSelectChapter(chapter)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(Self.startTimeText(chapter.startTime))
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.tint)
                            Text(chapter.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Chapter, \(chapter.title), starts at \(Self.startTimeText(chapter.startTime))")

                    if chapter.id != chapters.last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .accessibilityIdentifier("Episode Chapters Card")
    }

    static func startTimeText(_ startTime: TimeInterval) -> String {
        let pattern: Duration.TimeFormatStyle.Pattern = startTime >= 3600
            ? .hourMinuteSecond
            : .minuteSecond
        return Duration.seconds(max(startTime, 0)).formatted(.time(pattern: pattern))
    }
}

#Preview {
    EpisodeChaptersCard(
        chapters: [
            EpisodeChapter(id: 0, title: "Introduction", startTime: 0, endTime: 120),
            EpisodeChapter(id: 1, title: "Main Discussion", startTime: 120, endTime: 300),
            EpisodeChapter(id: 2, title: "Outro", startTime: 4_000, endTime: 4_100),
        ],
        source: .embedded
    ) { _ in }
    .padding()
}
