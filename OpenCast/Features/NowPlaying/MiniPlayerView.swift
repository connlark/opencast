import OpenCastCore
import OpenCastPlayback
import SwiftData
import SwiftUI

struct MiniPlayerView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isNowPlayingPresented: Bool
    let onExpand: () -> Void

    @State private var dismissDragOffsetY: CGFloat = 0
    @State private var dismissExitOffsetY: CGFloat = 0
    @State private var hasTriggeredDismissFeedback = false
    @State private var dismissFeedbackTrigger = 0
    @State private var playPauseFeedback = 0
    @State private var isTrackingDismissDrag = false
    @State private var isCompletingDismissal = false
    @State private var displayedEpisode: Episode?

    private static let cornerRadius: CGFloat = 28
    private static let dismissExitTravel: CGFloat = 420

    var body: some View {
        let state = appModel.playback.state
        let showsPauseButton = state == .playing || state == .buffering || state == .loading
        let currentEpisode = appModel.playback.currentEpisode
        // Keep the previous episode visible while the committed fly-down finishes.
        let renderedEpisode = currentEpisode ?? (isCompletingDismissal ? displayedEpisode : nil)

        if let episode = renderedEpisode {
            HStack(spacing: 12) {
                Button(action: expand) {
                    HStack(spacing: 10) {
                        ArtworkPlaceholder(
                            title: episode.podcastTitle,
                            imageURL: episode.artworkURL?.absoluteString,
                            size: 42,
                            cacheKind: .episode
                        )

                        Text("\(episode.title) - \(episode.podcastTitle)")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Now Playing")
                .accessibilityValue("\(episode.title), \(episode.podcastTitle)")

                Button(action: togglePlayPause) {
                    Image(systemName: showsPauseButton ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsPauseButton ? "Pause" : "Play")
                .accessibilityValue(state.accessibilityDescription)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius))
            .offset(y: dismissVisualOffsetY)
            .highPriorityGesture(dismissDragGesture)
            .allowsHitTesting(!isCompletingDismissal)
            .sensoryFeedback(.impact, trigger: dismissFeedbackTrigger)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: playPauseFeedback)
            .accessibilityElement(children: .contain)
            .accessibilityHidden(isNowPlayingPresented || isCompletingDismissal)
            .accessibilityAction(named: "Dismiss Player", beginDismissCommit)
            .onAppear {
                displayedEpisode = currentEpisode ?? displayedEpisode
            }
            .onChange(of: currentEpisode?.id.rawValue) { _, _ in
                updateDisplayedEpisode()
            }
        }
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged(updateDismissDrag)
            .onEnded(finishDismissDrag)
    }

    private var dismissVisualOffsetY: CGFloat {
        guard !reduceMotion else {
            return 0
        }

        return dismissDragOffsetY + dismissExitOffsetY
    }

    private func expand() {
        nowPlayingProbeMark("miniplayer-tap")
        onExpand()
    }

    private func dismissPlayer() {
        appModel.dismissCurrentPlayback(modelContext: modelContext)
    }

    private func togglePlayPause() {
        playPauseFeedback += 1
        appModel.playback.togglePlayPause()
    }

    private func updateDismissDrag(_ value: DragGesture.Value) {
        guard !isNowPlayingPresented, !isCompletingDismissal else {
            return
        }

        if !isTrackingDismissDrag {
            guard NowPlayingDragIntent.shouldStartMiniPlayerDismiss(translation: value.translation) else {
                return
            }

            isTrackingDismissDrag = true
        }

        updateDismissFeedback(for: value)

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dismissDragOffsetY = reduceMotion ? 0 : dismissOffset(for: value.translation)
        }
    }

    private func updateDismissFeedback(for value: DragGesture.Value) {
        guard !hasTriggeredDismissFeedback,
              NowPlayingDragIntent.shouldCompleteMiniPlayerDismiss(
                  translation: value.translation,
                  predictedEndTranslation: value.predictedEndTranslation
              )
        else {
            return
        }

        hasTriggeredDismissFeedback = true
        dismissFeedbackTrigger += 1
    }

    private func dismissOffset(for translation: CGSize) -> CGFloat {
        max(translation.height, 0)
    }

    private func finishDismissDrag(_ value: DragGesture.Value) {
        guard isTrackingDismissDrag else {
            return
        }

        isTrackingDismissDrag = false
        if NowPlayingDragIntent.shouldCompleteMiniPlayerDismiss(
            translation: value.translation,
            predictedEndTranslation: value.predictedEndTranslation
        ) {
            beginDismissCommit()
        } else {
            cancelDismissDrag()
        }
    }

    private func cancelDismissDrag() {
        hasTriggeredDismissFeedback = false
        guard !reduceMotion else {
            dismissDragOffsetY = 0
            return
        }

        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.88)) {
            dismissDragOffsetY = 0
        }
    }

    private func beginDismissCommit() {
        guard !isCompletingDismissal else {
            return
        }

        nowPlayingProbeMark("pill-dismiss-commit")
        hasTriggeredDismissFeedback = false

        let episodeID = appModel.playback.currentEpisode?.id.rawValue
        displayedEpisode = appModel.playback.currentEpisode ?? displayedEpisode
        isCompletingDismissal = true
        dismissExitOffsetY = 0

        guard !reduceMotion else {
            dismissPlayer()
            return
        }

        withAnimation(.easeIn(duration: 0.22)) {
            dismissExitOffsetY = Self.dismissExitTravel
        } completion: {
            finishDismissCommit(for: episodeID)
        }
    }

    private func finishDismissCommit(for episodeID: String?) {
        guard isCompletingDismissal else {
            return
        }

        guard appModel.playback.currentEpisode?.id.rawValue == episodeID else {
            resetDismissVisualState()
            return
        }

        dismissPlayer()
    }

    private func updateDisplayedEpisode() {
        if let currentEpisode = appModel.playback.currentEpisode {
            displayedEpisode = currentEpisode
            resetDismissVisualState()
        } else if !isCompletingDismissal {
            displayedEpisode = nil
        }
    }

    private func resetDismissVisualState() {
        dismissDragOffsetY = 0
        dismissExitOffsetY = 0
        hasTriggeredDismissFeedback = false
        isTrackingDismissDrag = false
        isCompletingDismissal = false
    }
}
