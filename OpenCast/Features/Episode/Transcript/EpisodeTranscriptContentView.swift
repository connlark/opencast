import OpenCastTranscription
import SwiftUI

/// Owns everything in the transcript page that churns with playback —
/// follow-along/karaoke state, scroll position, search, and the bottom
/// accessory — so 1 Hz position ticks and per-segment transitions never
/// re-evaluate the toolbar-owning parent (whose open "…" menu would flicker).
struct EpisodeTranscriptContentView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext

    let episodeID: String
    let document: EpisodeTranscriptDocument
    let timeline: TranscriptTimeline
    let searchIndex: TranscriptSearchIndex?
    let adSpanBySegmentID: [Int: EpisodeAdAnalysisSpan]
    let adAnalysisState: EpisodeAdAnalysisJobState
    let showsTimestamps: Bool
    @Binding var isSearchPresented: Bool

    @State private var activeSegmentID: Int?
    @State private var activeKaraokeLayout: TranscriptKaraokeLayout?
    @State private var tapPin: TranscriptTapPin?
    @State private var isFollowing = true
    @State private var interpolator: TranscriptPositionInterpolator?
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var searchQuery = ""
    @State private var isSearchInFlight = false
    @State private var matchSegmentIDs: [Int] = []
    @State private var highlightRangesBySegmentID: [Int: [Range<String.Index>]] = [:]
    @State private var currentMatchIndex: Int?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                TranscriptImprovementBanner(episodeID: episodeID)
                TranscriptAdAnalysisBanner(state: adAnalysisState)
                ForEach(document.segments) { segment in
                    EpisodeTranscriptLineView(
                        segment: segment,
                        isActive: segment.id == activeSegmentID,
                        isCurrentEpisode: isCurrentEpisode,
                        showsTimestamp: showsTimestamps,
                        adSpanLabel: adSpanBySegmentID[segment.id]?.label,
                        isAdSpanStart: adSpanBySegmentID[segment.id]?.startSegmentID == segment.id,
                        searchHighlightRanges: highlightRangesBySegmentID[segment.id],
                        karaokeInterpolator: karaokeInterpolator(for: segment),
                        karaokeLayout: segment.id == activeSegmentID ? activeKaraokeLayout : nil,
                        action: { playFrom(segment) }
                    )
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .scrollPosition($scrollPosition, anchor: .center)
        .scrollDismissesKeyboard(.interactively)
        .onScrollPhaseChange(handleScrollPhaseChange)
        .safeAreaInset(edge: .bottom) {
            bottomAccessory
        }
        .onChange(of: documentKey, initial: true) {
            resetForDocumentChange()
        }
        .task(id: documentKey) {
            await seedInitialScroll()
        }
        .task(id: searchTaskIdentifier) {
            await applySearchAfterDebounce()
        }
        .onChange(of: isSearchPresented) { _, isPresented in
            handleSearchPresentationChange(isPresented)
        }
        .onChange(of: currentPlaybackEpisodeID) { _, _ in
            handleCurrentEpisodeChange()
        }
        .background {
            TranscriptPlaybackObserver(
                onPositionTick: handlePositionTick,
                onStateChange: handlePlaybackStateChange,
                onProgressBoundary: handleProgressBoundaryChange
            )
        }
    }

    private var bottomAccessory: some View {
        VStack(spacing: 10) {
            if isSearchPresented {
                TranscriptSearchBar(
                    query: $searchQuery,
                    isSearching: isSearchInFlight,
                    matchCount: matchSegmentIDs.count,
                    currentMatchOrdinal: currentMatchIndex.map { $0 + 1 },
                    onPrevious: goToPreviousMatch,
                    onNext: goToNextMatch,
                    onClose: closeSearch
                )
            }
            if showsResumePill {
                TranscriptResumePill(action: resumeFollowing)
            }
            if !isCurrentEpisode {
                TranscriptPlayEpisodeButton(action: playEpisodeFromStart)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    // MARK: - Derived state

    /// Keyed off the loaded document value, not the parent's load identifier —
    /// that identifier flips before the async load lands, while this changes
    /// exactly when new content is actually on screen.
    private var documentKey: String {
        "\(document.episodeID)|\(document.updatedAt.timeIntervalSince1970)"
    }

    /// Re-running the search when the document reloads keeps highlight
    /// ranges pointing into the strings the rows are actually rendering.
    private var searchTaskIdentifier: String {
        "\(documentKey)|\(searchQuery)"
    }

    private var currentPlaybackEpisodeID: String? {
        appModel.playback.currentEpisode?.id.rawValue
    }

    private var isCurrentEpisode: Bool {
        currentPlaybackEpisodeID == episodeID
    }

    private var showsResumePill: Bool {
        isCurrentEpisode && !isFollowing && !isSearchPresented
    }

    private func karaokeInterpolator(for segment: OpenCastTranscriptSegment) -> TranscriptPositionInterpolator? {
        guard segment.id == activeSegmentID,
              segment.words != nil,
              appModel.playback.state == .playing
        else {
            return nil
        }
        return interpolator
    }

    // MARK: - Document lifecycle

    private func resetForDocumentChange() {
        tapPin = nil
        activeKaraokeLayout = nil
        clearSearchResults()
    }

    private func seedInitialScroll() async {
        syncPlaybackTick(force: true)
        guard isCurrentEpisode,
              let index = timeline.segmentIndex(at: appModel.playback.position)
        else {
            return
        }

        let segment = timeline.segments[index]
        setActiveSegment(segment, animated: false, scrolls: false)
        scrollPosition.scrollTo(id: segment.id, anchor: .center)
        // Lazy rows estimate heights on the first pass; re-center once real
        // layout has settled.
        try? await Task.sleep(for: .milliseconds(100))
        guard isFollowing, activeSegmentID == segment.id else {
            return
        }
        scrollPosition.scrollTo(id: segment.id, anchor: .center)
    }

    // MARK: - Follow-along

    private func handlePositionTick() {
        syncPlaybackTick()
        updateActiveSegment()
    }

    private func handlePlaybackStateChange() {
        syncPlaybackTick(force: true)
    }

    private func handleProgressBoundaryChange() {
        syncPlaybackTick(force: true)
        updateActiveSegment(animated: false)
    }

    /// Reseeds the interpolator only when it has drifted from the reported
    /// position (or on seeks/state changes via `force`); a steady 1 Hz tick
    /// stream that matches the interpolation leaves state untouched, so the
    /// screen does no per-tick re-rendering while following along.
    private func syncPlaybackTick(force: Bool = false) {
        let playback = appModel.playback
        let isPlaying = playback.state == .playing
        let rate = Double(playback.rate)
        if !force,
           let interpolator,
           interpolator.isPlaying == isPlaying,
           interpolator.rate == rate,
           abs(interpolator.estimatedTime(at: .now) - playback.position) < 0.35 {
            return
        }
        interpolator = TranscriptPositionInterpolator(
            basePosition: playback.position,
            baseDate: .now,
            rate: rate,
            isPlaying: isPlaying
        )
    }

    private func updateActiveSegment(animated: Bool = true) {
        guard isCurrentEpisode else {
            tapPin = nil
            setActiveSegment(nil)
            return
        }

        let position = appModel.playback.position
        let computedIndex = timeline.segmentIndex(at: position)

        if let tapPin {
            guard tapPin.shouldRelease(computedSegmentIndex: computedIndex, position: position) else {
                setActiveSegment(tapPin.segment, animated: animated, scrolls: false)
                return
            }
            self.tapPin = nil
        }

        let segment = computedIndex.map { timeline.segments[$0] }
        guard segment?.id != activeSegmentID else {
            return
        }
        setActiveSegment(segment, animated: animated)
    }

    private func setActiveSegment(
        _ segment: OpenCastTranscriptSegment?,
        animated: Bool = true,
        scrolls: Bool = true
    ) {
        if activeSegmentID != segment?.id {
            activeSegmentID = segment?.id
            activeKaraokeLayout = segment.flatMap(TranscriptKaraokeLayout.init)
        }
        guard scrolls, isFollowing, !isSearchPresented, let segment else {
            return
        }
        scrollToSegment(segment.id, animated: animated)
    }

    private func scrollToSegment(_ segmentID: Int, animated: Bool) {
        if animated && !reduceMotion {
            withAnimation(.smooth) {
                scrollPosition.scrollTo(id: segmentID, anchor: .center)
            }
        } else {
            scrollPosition.scrollTo(id: segmentID, anchor: .center)
        }
    }

    private func handleScrollPhaseChange(_ oldPhase: ScrollPhase, _ newPhase: ScrollPhase) {
        guard newPhase == .interacting else {
            return
        }
        isFollowing = false
    }

    private func resumeFollowing() {
        isFollowing = true
        updateActiveSegment()
        if let activeSegmentID {
            scrollToSegment(activeSegmentID, animated: true)
        }
    }

    private func handleCurrentEpisodeChange() {
        syncPlaybackTick(force: true)
        if isCurrentEpisode {
            isFollowing = true
            updateActiveSegment()
        } else {
            tapPin = nil
            setActiveSegment(nil)
        }
    }

    // MARK: - Playback actions

    private func playFrom(_ segment: OpenCastTranscriptSegment) {
        if isCurrentEpisode {
            if let segmentIndex = timeline.segmentIndex(at: segment.start) {
                tapPin = TranscriptTapPin(segment: segment, segmentIndex: segmentIndex)
            }
            appModel.playback.seek(to: segment.start, intent: .scrub)
            if appModel.playback.state != .playing {
                appModel.playback.play()
            }
            isFollowing = true
            setActiveSegment(segment, animated: true)
        } else {
            playEpisode(at: segment.start)
        }
    }

    private func playEpisodeFromStart() {
        playEpisode(at: nil)
    }

    private func playEpisode(at startPosition: TimeInterval?) {
        guard let snapshot = appModel.library.episode(with: episodeID) else {
            appModel.lastPlaybackError = "This episode is no longer in the library."
            return
        }

        do {
            try appModel.playEpisode(
                snapshot,
                at: startPosition,
                presentsNowPlaying: false,
                modelContext: modelContext
            )
            isFollowing = true
        } catch {
            appModel.lastPlaybackError = error.localizedDescription
        }
    }

    // MARK: - Search

    private func closeSearch() {
        isSearchPresented = false
    }

    private func applySearchAfterDebounce() async {
        guard !searchQuery.isEmpty else {
            clearSearchResults()
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            return
        }
        guard let searchIndex else {
            return
        }

        isSearchInFlight = true
        let query = searchQuery
        let result = await Task.detached(priority: .userInitiated) {
            searchIndex.result(for: query)
        }.value
        guard !Task.isCancelled, searchQuery == query else {
            return
        }

        isSearchInFlight = false
        matchSegmentIDs = result.matchSegmentIDs
        highlightRangesBySegmentID = result.highlightRangesBySegmentID
        currentMatchIndex = result.matchSegmentIDs.isEmpty ? nil : 0
        if let firstID = result.matchSegmentIDs.first {
            scrollToSegment(firstID, animated: true)
        }
    }

    private func clearSearchResults() {
        isSearchInFlight = false
        matchSegmentIDs = []
        highlightRangesBySegmentID = [:]
        currentMatchIndex = nil
    }

    private func goToPreviousMatch() {
        stepMatch(by: -1)
    }

    private func goToNextMatch() {
        stepMatch(by: 1)
    }

    private func stepMatch(by delta: Int) {
        guard !matchSegmentIDs.isEmpty else {
            return
        }

        let count = matchSegmentIDs.count
        let next = ((currentMatchIndex ?? 0) + delta + count) % count
        currentMatchIndex = next
        scrollToSegment(matchSegmentIDs[next], animated: true)
    }

    private func handleSearchPresentationChange(_ isPresented: Bool) {
        guard !isPresented else {
            return
        }

        searchQuery = ""
        clearSearchResults()
        guard isCurrentEpisode else {
            return
        }
        isFollowing = true
        if let activeSegmentID {
            scrollToSegment(activeSegmentID, animated: true)
        }
    }
}
