import OpenCastTranscription
import SwiftData
import SwiftUI

/// Owns everything that churns with playback, so position ticks and segment transitions never
/// re-evaluate the toolbar-owning parent, whose open menu would flicker.
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
    let adSpanBySegmentID: [Int: TranscriptAdHighlight]
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
                        isAdSpanStart: adSpanBySegmentID[segment.id]?.isStart == true,
                        searchHighlightRanges: searchSession.highlightRangesBySegmentID[segment.id],
                        karaokeSpokenUpperBound: segment.id == activeSegmentID ? karaokeSpokenUpperBound : nil,
                        karaokeLayout: segment.id == activeSegmentID ? activeKaraokeLayout : nil,
                        adHighlight: adSpanBySegmentID[segment.id],
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
            // A switchable mismatch auto-resolves once, so the banner is only the manual
            // fallback after that attempt failed to converge.
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

    /// Not the parent's load identifier: that flips before the async load lands, while this
    /// changes exactly when new content is on screen.
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

    private var isSourceVerified: Bool {
        sourceAlignment == .verified
    }

    /// The player item is not observable, so playback state and duration stand in as trip-wires:
    /// every path that replaces the item or establishes its timeline publishes through them.
    private var sourceAlignmentTaskID: String {
        let downloadStamp = appModel.downloads.record(for: episodeID)?.updatedAt.timeIntervalSince1970 ?? -1
        let playbackStamp = "\(appModel.playback.duration ?? -1)|\(String(describing: appModel.playback.state))"
        return "\(documentKey)|\(currentPlaybackEpisodeID ?? "none")|\(currentPlaybackAudioURL?.absoluteString ?? "none")|\(playbackStamp)|\(downloadStamp)"
    }

    /// The scene phase is in the key so backgrounding cancels the stream and removes the player
    /// observer; on return, the stream's prime sample reconciles at once.
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

    /// One automatic attempt per document view: if it cannot converge, the banner offers the
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
        // While unverified, re-resolve on each tick, so a missed observation (item swap,
        // deferred asset load) never leaves follow-along suspended against a now-proven item.
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

    /// Idempotent: every sample is a wake-up, never an event to count, so dropped, coalesced or
    /// duplicated callbacks and seeks in either direction self-heal here.
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
            // The stored bound indexes the previous layout's text, so it is cleared in the same
            // pass that replaces the layout; a stale index must never slice the new text.
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

    /// The carried position is approximate across assemblies, but every karaoke frame afterward is
    /// exact. Pause state is kept so the automatic switch never starts audio the user stopped.
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
