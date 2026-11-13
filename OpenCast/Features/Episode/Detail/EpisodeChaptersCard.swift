import OpenCastCore
import SwiftUI

/// Chapter list on episode detail: title + start time, tap seeks. Renders
/// chapters embedded in the audio file, the feed's chapters document, or a
/// current generated analysis. Publisher and generated rows carry a tag
/// naming their source; embedded rows, part of the audio itself, carry none.
struct EpisodeChaptersCard: View {
    enum Source {
        case embedded
        case publisher
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
                switch source {
                case .embedded:
                    EmptyView()
                case .publisher:
                    PublisherContentTag()
                case .generated:
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

    /// Clamped, because `Duration.seconds` traps on a NaN or a value past
    /// its range and chapters arrive from feeds and files.
    static func startTimeText(_ startTime: TimeInterval) -> String {
        let seconds = startTime.isNaN
            ? 0
            : min(max(startTime, 0), PublisherChaptersDocumentDecoder.maximumTimestamp)
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600
            ? .hourMinuteSecond
            : .minuteSecond
        return Duration.seconds(seconds).formatted(.time(pattern: pattern))
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

#Preview("From the publisher") {
    EpisodeChaptersCard(
        chapters: [
            EpisodeChapter(id: 0, title: "Cold Open", startTime: 0),
            EpisodeChapter(id: 1, title: "Listener Mail", startTime: 133.56, endTime: 900),
            EpisodeChapter(id: 2, title: "Closing Thoughts", startTime: 3_700),
        ],
        source: .publisher
    ) { _ in }
    .padding()
}
