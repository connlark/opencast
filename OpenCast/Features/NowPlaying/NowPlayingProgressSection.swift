import OpenCastCore
import SwiftUI

/// Owns every body-level playback-position read on Now Playing — the 1 Hz
/// tick re-evaluates only this section, keeping the parent (and its open "…"
/// menu) stable while time advances. The chapter bar lives here for the same
/// reason: the current chapter is a function of the position.
struct NowPlayingProgressSection: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var scrubPosition: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var scrubFeedback = 0
    @State private var chapterSkipFeedback = 0
    @State private var scrubbingEpisodeID: String?
    @State private var pendingSeekPosition: TimeInterval?

    let onShowChapters: () -> Void

    private static let pendingSeekTolerance: TimeInterval = 1.5

    var body: some View {
        let chapters = appModel.currentEpisodeChapters

        VStack(spacing: 10) {
            NowPlayingProgressView(
                duration: appModel.playback.duration,
                displayedPosition: displayedPosition,
                zones: appModel.playback.skipZones,
                displayOnlyZones: appModel.displayOnlySkipZones,
                chapterBoundaries: chapters.timelineMarkers,
                scrubPosition: $scrubPosition,
                onEditingChanged: updateScrubbing
            )

            if !chapters.isEmpty {
                NowPlayingChapterBar(
                    chapters: chapters,
                    position: displayedPosition,
                    onSkipToPrevious: { skipToPreviousChapter(in: chapters) },
                    onSkipToNext: { skipToNextChapter(in: chapters) },
                    onShowChapters: onShowChapters
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: chapters.isEmpty)
        .sensoryFeedback(.selection, trigger: scrubFeedback)
        .sensoryFeedback(.selection, trigger: chapterSkipFeedback)
        .onAppear {
            scrubPosition = appModel.playback.position
        }
        .onChange(of: observedPosition) { _, newPosition in
            guard let newPosition, !isScrubbing else {
                return
            }
            if let pendingSeekPosition, abs(newPosition - pendingSeekPosition) <= Self.pendingSeekTolerance {
                self.pendingSeekPosition = nil
            }
            scrubPosition = newPosition
        }
        .onChange(of: currentEpisodeID) { _, _ in
            isScrubbing = false
            pendingSeekPosition = nil
            scrubPosition = appModel.playback.position
        }
        .onChange(of: appModel.isNowPlayingPresented) { _, isPresented in
            if !isPresented {
                isScrubbing = false
                scrubbingEpisodeID = nil
                pendingSeekPosition = nil
            }
        }
        .task(id: pendingSeekPosition) {
            guard pendingSeekPosition != nil else {
                return
            }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else {
                return
            }
            pendingSeekPosition = nil
        }
    }

    private var currentEpisodeID: String? {
        appModel.playback.currentEpisode?.id.rawValue
    }

    private var displayedPosition: TimeInterval {
        if isScrubbing {
            return scrubPosition
        }
        return pendingSeekPosition ?? observedPosition ?? scrubPosition
    }

    private var observedPosition: TimeInterval? {
        // The prepared card remains mounted behind the tabs. Avoid subscribing
        // to its playback clock until visible, including during background audio.
        appModel.isNowPlayingPresented && scenePhase == .active ? appModel.playback.position : nil
    }

    private func updateScrubbing(_ editing: Bool) {
        if editing {
            scrubbingEpisodeID = currentEpisodeID
            isScrubbing = true
            scrubFeedback += 1
        } else {
            // A release after the episode changed mid-drag must not seek the new
            // episode to a position chosen on the old episode's timeline.
            guard scrubbingEpisodeID == currentEpisodeID else {
                isScrubbing = false
                scrubPosition = appModel.playback.position
                return
            }

            let seekPosition = scrubPosition
            isScrubbing = false
            pendingSeekPosition = seekPosition
            appModel.playback.seek(to: seekPosition)
        }
    }

    private func skipToPreviousChapter(in chapters: PlaybackChapterList) {
        guard let chapter = chapters.previousChapter(before: displayedPosition) else {
            return
        }
        skip(to: chapter, in: chapters)
    }

    private func skipToNextChapter(in chapters: PlaybackChapterList) {
        guard let chapter = chapters.nextChapter(after: displayedPosition) else {
            return
        }
        skip(to: chapter, in: chapters)
    }

    private func skip(to chapter: EpisodeChapter, in chapters: PlaybackChapterList) {
        chapterSkipFeedback += 1
        isScrubbing = false
        scrubPosition = chapter.startTime
        pendingSeekPosition = chapter.startTime
        appModel.seekCurrentEpisode(toChapter: chapter, in: chapters, modelContext: modelContext)
    }
}
