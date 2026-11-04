import OpenCastCore
import SwiftData
import SwiftUI

struct NowPlayingChaptersView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var host: NowPlayingSecondaryHost = .sheet

    var body: some View {
        let chapters = appModel.currentEpisodeChapters
        let current = chapters.chapter(at: appModel.playback.position)

        NavigationStack {
            Group {
                if chapters.isEmpty {
                    ContentUnavailableView("No Chapters", systemImage: "list.bullet")
                } else {
                    List(chapters.chapters) { chapter in
                        Button {
                            select(chapter, in: chapters)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(EpisodeChaptersCard.startTimeText(chapter.startTime))
                                    .font(.subheadline)
                                    .monospacedDigit()
                                    .foregroundStyle(.tint)
                                Text(chapter.title)
                                    .font(.body)
                                    .fontWeight(chapter == current ? .semibold : .regular)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                                if chapter == current {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .accessibilityLabel(
                            "Chapter, \(chapter.title), starts at \(EpisodeChaptersCard.startTimeText(chapter.startTime))"
                        )
                        .accessibilityValue(chapter == current ? "Now playing" : "")
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if host.showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("Now Playing Chapters")
    }

    private func select(_ chapter: EpisodeChapter, in chapters: PlaybackChapterList) {
        appModel.seekCurrentEpisode(toChapter: chapter, in: chapters, modelContext: modelContext)
        if host.dismissesAfterSelection {
            dismiss()
        }
    }
}
