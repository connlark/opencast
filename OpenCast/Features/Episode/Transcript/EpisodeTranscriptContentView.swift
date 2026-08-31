import OpenCastTranscription
import SwiftUI

/// Owns everything in the transcript page that churns with playback —
/// follow-along/karaoke state, scroll position, search, and the bottom
/// accessory — so 1 Hz position ticks and per-segment transitions never
/// re-evaluate the toolbar-owning parent (whose open "…" menu would flicker).
struct EpisodeTranscriptContentView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isAppStoreScreenshotCapture) private var isAppStoreScreenshotCapture
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
    @State private var sourceAlignment: TranscriptSourceAlignment?
    @State private var hasAutoSwitchedToTranscribedCopy = false
    @State private var activeKaraokeLayout: TranscriptKaraokeLayout?
    @State private var karaokeSpokenUpperBound: String.Index?
    @State private var tapPin: TranscriptTapPin?
    @State private var isFollowing = true
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var searchQuery = ""
    @State private var searchSession = TranscriptSearchSession()

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
                        searchHighlightRanges: searchSession.highlightRangesBySegmentID[segment.id],
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
        .scrollIndicators(.visible)
        .scrollPosition($scrollPosition, anchor: .center)
        .scrollDismissesKeyboard(.interactively)
        .onScrollPhaseChange(handleScrollPhaseChange)
        .safeAreaInset(edge: .bottom) {
            bottomAccessory
        }
        .onChange(of: documentKey, initial: true) {
            resetForDocumentChange()
        }
        .task(id: sourceAlignmentTaskID) {
            reconcileSourceAlignment()
        }
        .task(id: "\(documentKey)|\(isSourceVerified)") {
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
                    isSearching: searchSession.isInFlight,
                    matchCount: searchSession.matchSegmentIDs.count,
                    currentMatchOrdinal: searchSession.currentMatchIndex.map { $0 + 1 },
                    onPrevious: goToPreviousMatch,
                    onNext: goToNextMatch,
                    onClose: closeSearch
                )
            }
            if showsResumePill {
                TranscriptResumePill(action: resumeFollowing)
            }
            // The switchable state auto-resolves (`autoSwitchToTranscribedCopyIfNeeded`),
            // so its banner only appears as the manual fallback after that
            // one automatic attempt failed to converge.
            if !isSearchPresented,
               case .mismatched(let canSwitchToTranscribedCopy)? = sourceAlignment,
               hasAutoSwitchedToTranscribedCopy || !canSwitchToTranscribedCopy {
                TranscriptSourceMismatchBanner(
                    canSwitchToTranscribedCopy: canSwitchToTranscribedCopy,
                    switchToTranscribedCopy: switchToTranscribedCopy
                )
            }
            // Marketing shots keep the flagged sponsor read unobstructed.
            if !isCurrentEpisode, !isAppStoreScreenshotCapture {
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
        isCurrentEpisode && isSourceVerified && !isFollowing && !isSearchPresented
    }

    private var currentPlaybackAudioURL: URL? {
        appModel.playback.currentEpisode?.audioURL
    }

    /// Follow-along/karaoke may run only against the exact audio asset the
    /// transcript describes; a dynamic enclosure URL returns byte-different
    /// assemblies per request, so an unproven player item must not be
    /// highlighted as though it were the transcribed audio.
    private var isSourceVerified: Bool {
        sourceAlignment == .verified
    }

    /// The verdict can only change when the player item, current episode,
    /// document, or download record changes — never on position ticks. The
    /// actual player item is not observable, so the observable playback
    /// state and duration stand in as trip-wires: every path that replaces
    /// the item or establishes its timeline (load, retry, cache fallback,
    /// duration resolution) publishes through them.
    private var sourceAlignmentTaskID: String {
        let downloadStamp = appModel.downloads.record(for: episodeID)?.updatedAt.timeIntervalSince1970 ?? -1
        let playbackStamp = "\(appModel.playback.duration ?? -1)|\(String(describing: appModel.playback.state))"
        return "\(documentKey)|\(currentPlaybackEpisodeID ?? "none")|\(currentPlaybackAudioURL?.absoluteString ?? "none")|\(playbackStamp)|\(downloadStamp)"
    }

    /// Restarting on identity changes tears the media-clock stream down for
    /// dismissals, document reloads, current-episode flips, and backgrounding
    /// via the `.task(id:)` cancellation, which removes the player observer.
    /// On return to the foreground the stream's prime sample reconciles
    /// immediately; the 1 Hz observer keeps segments current meanwhile.
    private var mediaClockTaskID: String {
        "\(documentKey)|\(isCurrentEpisode)|\(isSourceVerified)|\(scenePhase == .active)"
    }

    private var isKaraokeCapable: Bool {
        document.segments.contains { $0.words != nil }
    }

    // MARK: - Document lifecycle

    private func resetForDocumentChange() {
        tapPin = nil
        activeKaraokeLayout = nil
        karaokeSpokenUpperBound = nil
        hasAutoSwitchedToTranscribedCopy = false
        clearSearchResults()
    }

    private func reconcileSourceAlignment() {
        let alignment = isCurrentEpisode ? resolveSourceAlignment() : nil
        if sourceAlignment != alignment {
            sourceAlignment = alignment
            reconcile(position: appModel.playback.position)
        }
        autoSwitchToTranscribedCopyIfNeeded()
    }

    /// Opening the transcript should not require pressing the switch button:
    /// when the matched copy exists but the player is on a different asset,
    /// switch to it once automatically, preserving pause state. One attempt
    /// per document view — if it cannot converge, the banner offers the
    /// manual path instead of looping.
    private func autoSwitchToTranscribedCopyIfNeeded() {
        guard !hasAutoSwitchedToTranscribedCopy,
              case .mismatched(canSwitchToTranscribedCopy: true)? = sourceAlignment
        else {
            return
        }
        hasAutoSwitchedToTranscribedCopy = true
        switchToTranscribedCopy()
        let refreshed = isCurrentEpisode ? resolveSourceAlignment() : nil
        if sourceAlignment != refreshed {
            sourceAlignment = refreshed
            reconcile(position: appModel.playback.position)
        }
    }

    private func resolveSourceAlignment() -> TranscriptSourceAlignment {
        let downloadRecord = appModel.downloads.record(for: episodeID)
        return TranscriptSourceAlignment.resolve(
            documentSHA256: document.sourceFileSHA256,
            trustedDownloadSHA256: appModel.downloads.completedSourceIdentity(for: episodeID)?.sha256,
            downloadFileURL: downloadRecord.flatMap(appModel.downloads.localFileURL(for:)),
            playerItemURL: appModel.playback.currentItemSourceIdentity?.assetURL
        )
    }

    private func seedInitialScroll() async {
        guard isCurrentEpisode,
              isSourceVerified,
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
        // Self-healing convergence: while unverified, re-resolve on the 1 Hz
        // tick so a missed observation (item swap, deferred asset load) can
        // never leave follow-along suspended against a now-proven item.
        if sourceAlignment != .verified {
            reconcileSourceAlignment()
        }
        reconcile(position: appModel.playback.position)
    }

    private func handlePlaybackStateChange() {
        reconcile(position: appModel.playback.position)
    }

    private func handleProgressBoundaryChange() {
        reconcile(position: appModel.playback.position, animated: false)
    }

    private func consumeMediaClock() async {
        guard isCurrentEpisode, isSourceVerified, isKaraokeCapable, scenePhase == .active else {
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
        guard isCurrentEpisode, isSourceVerified else {
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
            // Becoming current again re-arms the one-shot automatic switch.
            hasAutoSwitchedToTranscribedCopy = false
            reconcile(position: appModel.playback.position)
        } else {
            tapPin = nil
            setActiveSegment(nil, index: nil)
        }
    }

    // MARK: - Playback actions

    private func playFrom(_ segment: OpenCastTranscriptSegment) {
        guard isCurrentEpisode else {
            playEpisode(at: segment.start)
            return
        }

        switch sourceAlignment ?? resolveSourceAlignment() {
        case .verified:
            let segmentIndex = timeline.segmentIndex(at: segment.start)
            if let segmentIndex {
                tapPin = TranscriptTapPin(segment: segment, segmentIndex: segmentIndex)
            }
            appModel.playback.seek(to: segment.start, intent: .scrub)
            playIfPaused()
            isFollowing = true
            setActiveSegment(segment, index: segmentIndex, animated: true)
        case .mismatched(canSwitchToTranscribedCopy: true):
            // Seeking the unproven item cannot honor the tapped line;
            // restarting from the matched download at that line can.
            playEpisode(at: segment.start)
        case .mismatched(canSwitchToTranscribedCopy: false):
            // Explicit best-effort jump. Follow-along stays suspended, so the
            // approximate landing is never presented as synchronized.
            appModel.playback.seek(to: segment.start, intent: .scrub)
            playIfPaused()
        }
    }

    private func playIfPaused() {
        if appModel.playback.state != .playing {
            appModel.playback.play()
        }
    }

    private func playEpisodeFromStart() {
        playEpisode(at: nil)
    }

    /// Carrying the numeric position across assemblies is approximate (they
    /// differ by inserted content), but every karaoke frame afterward is
    /// exact against the transcribed copy. Pause state is preserved so the
    /// automatic switch never starts audio the user had stopped.
    private func switchToTranscribedCopy() {
        let wantsAudio = switch appModel.playback.state {
        case .playing, .buffering, .loading:
            true
        case .idle, .paused, .failed:
            false
        }
        playEpisode(at: appModel.playback.position, autoplay: wantsAudio)
    }

    private func playEpisode(at startPosition: TimeInterval?, autoplay: Bool = true) {
        // The snapshot fallback covers episodes visible only through their
        // download record; the library lookup alone would silently no-op.
        guard let snapshot = appModel.episodeSnapshot(for: episodeID) else {
            appModel.lastPlaybackError = "This episode is no longer in the library."
            return
        }

        do {
            try appModel.playEpisode(
                snapshot,
                at: startPosition,
                matchingSourceSHA256: document.sourceFileSHA256,
                presentsNowPlaying: false,
                autoplay: autoplay,
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

        let query = searchQuery
        do {
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            return
        }
        guard searchQuery == query, let searchIndex else {
            return
        }

        let generation = searchSession.begin(query: query)
        defer {
            searchSession.finish(generation: generation)
        }

        let result: TranscriptSearchResult
        do {
            result = try await searchIndex.result(for: query)
            try Task.checkCancellation()
        } catch {
            return
        }
        guard searchQuery == query,
              searchSession.publish(result, generation: generation)
        else {
            return
        }

        if let firstID = result.matchSegmentIDs.first {
            scrollToSegment(firstID, animated: true)
        }
    }

    private func clearSearchResults() {
        searchSession.clear()
    }

    private func goToPreviousMatch() {
        stepMatch(by: -1)
    }

    private func goToNextMatch() {
        stepMatch(by: 1)
    }

    private func stepMatch(by delta: Int) {
        guard let segmentID = searchSession.stepMatch(by: delta) else {
            return
        }
        scrollToSegment(segmentID, animated: true)
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
