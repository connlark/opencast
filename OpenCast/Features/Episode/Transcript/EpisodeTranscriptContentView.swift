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
    @Environment(\.scenePhase) private var scenePhase

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
    @State private var karaokeSpokenUpperBound: String.Index?
    @State private var tapPin: TranscriptTapPin?
    @State private var isFollowing = true
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
                        karaokeSpokenUpperBound: segment.id == activeSegmentID ? karaokeSpokenUpperBound : nil,
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
        .task(id: mediaClockTaskID) {
            await consumeMediaClock()
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

    /// Restarting on identity changes tears the media-clock stream down for
    /// dismissals, document reloads, current-episode flips, and backgrounding
    /// via the `.task(id:)` cancellation, which removes the player observer.
    /// On return to the foreground the stream's prime sample reconciles
    /// immediately; the 1 Hz observer keeps segments current meanwhile.
    private var mediaClockTaskID: String {
        "\(documentKey)|\(isCurrentEpisode)|\(scenePhase == .active)"
    }

    private var isKaraokeCapable: Bool {
        document.segments.contains { $0.words != nil }
    }

    // MARK: - Document lifecycle

    private func resetForDocumentChange() {
        tapPin = nil
        activeKaraokeLayout = nil
        karaokeSpokenUpperBound = nil
        clearSearchResults()
    }

    private func seedInitialScroll() async {
        guard isCurrentEpisode,
              let index = timeline.segmentIndex(at: appModel.playback.position)
        else {
            return
        }

        let segment = timeline.segments[index]
        setActiveSegment(segment, index: index, animated: false, scrolls: false)
        applySpokenUpperBound(at: appModel.playback.position)
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
        reconcile(position: appModel.playback.position)
    }

    private func handlePlaybackStateChange() {
        reconcile(position: appModel.playback.position)
    }

    private func handleProgressBoundaryChange() {
        reconcile(position: appModel.playback.position, animated: false)
    }

    private func consumeMediaClock() async {
        guard isCurrentEpisode, isKaraokeCapable, scenePhase == .active else {
            return
        }
        for await sample in appModel.playback.mediaClockSamples() {
            reconcile(position: sample.position)
        }
    }

    /// The single idempotent reconciliation both the media clock and the 1 Hz
    /// observer converge on: resolve the complete highlight state for the
    /// given media position, publishing only what actually changed. Every
    /// sample is a wake-up, never an event to count, so dropped, coalesced,
    /// or duplicated callbacks and seeks in either direction self-heal here.
    private func reconcile(position: TimeInterval, animated: Bool = true) {
        guard isCurrentEpisode else {
            tapPin = nil
            setActiveSegment(nil, index: nil)
            return
        }

        let computedIndex = timeline.segmentIndex(at: position)

        if let tapPin {
            guard tapPin.shouldRelease(computedSegmentIndex: computedIndex, position: position) else {
                setActiveSegment(tapPin.segment, index: tapPin.segmentIndex, animated: animated, scrolls: false)
                applySpokenUpperBound(at: position.clamped(to: tapPin.segment.start...tapPin.segment.end))
                return
            }
            self.tapPin = nil
        }

        let segment = computedIndex.map { timeline.segments[$0] }
        if segment?.id != activeSegmentID {
            setActiveSegment(segment, index: computedIndex, animated: animated)
        }
        applySpokenUpperBound(at: position)
    }

    private func applySpokenUpperBound(at position: TimeInterval) {
        let frame = TranscriptKaraokeReducer.frame(
            at: position,
            timeline: timeline,
            activeLayout: activeKaraokeLayout
        )
        let newBound = frame.segmentID == activeSegmentID ? frame.spokenUpperBound : nil
        if karaokeSpokenUpperBound != newBound {
            karaokeSpokenUpperBound = newBound
        }
    }

    private func setActiveSegment(
        _ segment: OpenCastTranscriptSegment?,
        index: Int?,
        animated: Bool = true,
        scrolls: Bool = true
    ) {
        if activeSegmentID != segment?.id {
            activeSegmentID = segment?.id
            // The stored bound indexes the previous layout's text; nil it in
            // the same pass the layout is replaced so a stale index can never
            // slice the new text.
            karaokeSpokenUpperBound = nil
            if let segment {
                let handoff = index.map(timeline.handoff(afterSegmentAt:)) ?? .infinity
                activeKaraokeLayout = TranscriptKaraokeLayout(segment: segment, handoff: handoff)
            } else {
                activeKaraokeLayout = nil
            }
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
        reconcile(position: appModel.playback.position)
        if let activeSegmentID {
            scrollToSegment(activeSegmentID, animated: true)
        }
    }

    private func handleCurrentEpisodeChange() {
        if isCurrentEpisode {
            isFollowing = true
            reconcile(position: appModel.playback.position)
        } else {
            tapPin = nil
            setActiveSegment(nil, index: nil)
        }
    }

    // MARK: - Playback actions

    private func playFrom(_ segment: OpenCastTranscriptSegment) {
        if isCurrentEpisode {
            let segmentIndex = timeline.segmentIndex(at: segment.start)
            if let segmentIndex {
                tapPin = TranscriptTapPin(segment: segment, segmentIndex: segmentIndex)
            }
            appModel.playback.seek(to: segment.start, intent: .scrub)
            if appModel.playback.state != .playing {
                appModel.playback.play()
            }
            isFollowing = true
            setActiveSegment(segment, index: segmentIndex, animated: true)
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
