import SwiftUI

/// Generated chapter list on episode detail: title + start time, tap seeks.
/// Rendered only for a current (fingerprint-matching) analysis document.
struct EpisodeChaptersCard: View {
    let chapters: [EpisodeTranscriptAnalysisChapter]
    let onSelectChapter: (EpisodeTranscriptAnalysisChapter) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Chapters", systemImage: "list.bullet")
                    .font(.headline)
                Spacer()
                GeneratedContentTag()
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
    }

    static func startTimeText(_ startTime: TimeInterval) -> String {
        let pattern: Duration.TimeFormatStyle.Pattern = startTime >= 3600
            ? .hourMinuteSecond
            : .minuteSecond
        return Duration.seconds(max(startTime, 0)).formatted(.time(pattern: pattern))
    }
}
