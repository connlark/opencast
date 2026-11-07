import Testing
@testable import OpenCast

/// The post-install refresh: a tab inserted with an empty title keeps its
/// symbol's description as its hosted label until the declarations are next
/// evaluated (observed on the iPhone Duo simulator), so each installation gets
/// one further update, through a fresh generation.
@MainActor
@Suite("Tab refreshes")
struct TabRefreshesTests {
    private typealias Refreshes = OpenCastTabRootView.TabRefreshes
    private static let launchSet: Set<AppSection> = [.library, .inbox, .downloads, .settings, .search]

    @Test("The initial membership takes a generation each, every one distinct")
    func initialMembership() {
        var refreshes = Refreshes()
        let change = refreshes.observe(Self.launchSet)
        #expect(Set(change.added.map(\.section)) == Self.launchSet)
        #expect(Set(change.added.map(\.generation)).count == Self.launchSet.count)
        #expect(change.withdrawn.isEmpty)
    }

    @Test("A late Playlists and a late Up Next each take their own")
    func lateInstallations() throws {
        var refreshes = Refreshes()
        _ = refreshes.observe(Self.launchSet)
        let library = refreshes.generation(of: .library)

        let playlists = try #require(refreshes.observe(Self.launchSet.union([.playlists])).added.first)
        let upNext = try #require(refreshes.observe(Self.launchSet.union([.playlists, .upNext])).added.first)
        #expect(playlists.section == .playlists)
        #expect(upNext.section == .upNext)
        #expect(playlists.generation != upNext.generation)
        #expect(refreshes.generation(of: .library) == library)
    }

    @Test("Unchanged membership is a no-op: nothing to refresh, the stored value equal")
    func duplicateObservation() {
        var refreshes = Refreshes()
        _ = refreshes.observe(Self.launchSet)
        let once = refreshes
        let change = refreshes.observe(Self.launchSet)
        #expect(change.added.isEmpty)
        #expect(change.withdrawn.isEmpty)
        #expect(refreshes == once)
    }

    @Test("Recording an installation changes the stored value, which is what re-evaluates the helper")
    func recordingChangesTheStoredValue() {
        var refreshes = Refreshes()
        _ = refreshes.observe(Self.launchSet)
        let before = refreshes
        _ = refreshes.observe(Self.launchSet.union([.upNext]))
        #expect(refreshes != before)
    }

    @Test("Withdrawal before the refresh clears the generation, reported once")
    func withdrawalBeforeTheRefresh() throws {
        var refreshes = Refreshes()
        let upNext = try #require(refreshes.observe([.upNext]).added.first)
        #expect(refreshes.observe([]).withdrawn == [upNext])
        #expect(refreshes.generation(of: .upNext) == nil)
        #expect(refreshes.observe([]).withdrawn.isEmpty)
    }

    @Test("A reinstallation takes a fresh token, never an earlier one")
    func reinstallation() throws {
        var refreshes = Refreshes()
        var seen: Set<Int> = []
        for _ in 0 ..< 4 {
            let installation = try #require(refreshes.observe([.upNext]).added.first)
            #expect(seen.insert(installation.generation).inserted)
            _ = refreshes.observe([])
        }
    }

    @Test("Eligibility loss alone clears nothing while the tab stays installed awaiting handover")
    func eligibilityLossKeepsTheGeneration() throws {
        var refreshes = Refreshes()
        let upNext = try #require(refreshes.observe([.upNext, .library]).added.first { $0.section == .upNext })

        // No longer offered, still selected: the step hands over, membership holds.
        let step = OpenCastTabRootView.upNextTabStep(
            isOffered: false,
            isShown: true,
            selection: .upNext,
            observedSelection: .upNext,
            isHandoverPending: false
        )
        #expect(step == .handOverToLibrary)
        _ = refreshes.observe([.upNext, .library])
        #expect(refreshes.generation(of: .upNext) == upNext.generation)
    }

    @Test("A late-latched root: the latch changes the form, not a generation")
    func lateLatchedRoot() throws {
        var refreshes = Refreshes()
        _ = refreshes.observe(Self.launchSet.union([.playlists]))
        let beforeLatch = refreshes
        #expect(TabLabelForm.resolve(isFoldableScene: false) == .titled)

        #expect(TabLabelForm.resolve(isFoldableScene: true) == .iconOnly)
        #expect(refreshes == beforeLatch)

        let upNext = try #require(refreshes.observe(Self.launchSet.union([.playlists, .upNext])).added.first)
        #expect(upNext.section == .upNext)
        #expect(refreshes.generation(of: .library) == beforeLatch.generation(of: .library))
    }

    @Test("An initially latched root: all seven take a generation from the first observation")
    func initiallyLatchedRoot() {
        var refreshes = Refreshes()
        let change = refreshes.observe(Set(AppSection.allCases))
        #expect(change.added.count == AppSection.allCases.count)
        #expect(Set(change.added.map(\.generation)).count == AppSection.allCases.count)
    }

    @Test("Membership writes coalesced without an observed withdrawal are no installation")
    func coalescedMembership() {
        var refreshes = Refreshes()
        _ = refreshes.observe([.upNext, .library])
        let once = refreshes

        // Withdrawn and reinstalled between two updates: the observer sees one
        // unchanged set, and the tab it never saw leave keeps its generation.
        let change = refreshes.observe([.upNext, .library])
        #expect(change.added.isEmpty)
        #expect(change.withdrawn.isEmpty)
        #expect(refreshes == once)
    }

    #if DEBUG
    @Test("A refresh is credited once, when an evaluation consumes the generation")
    func consumptionAccounting() {
        let log = OpenCastTabRootView.TabEvaluationLog()
        #expect(log.noteEvaluation(of: .upNext, generation: 7))
        #expect(!log.noteEvaluation(of: .upNext, generation: 7))
        #expect(log.refreshCount == 1)
    }

    @Test("Several installations can share one evaluation, each credited")
    func sharedEvaluation() {
        let log = OpenCastTabRootView.TabEvaluationLog()
        #expect(log.noteEvaluation(of: .library, generation: 1))
        #expect(log.noteEvaluation(of: .inbox, generation: 2))
        #expect(log.refreshCount == 2)
    }

    @Test("An installation withdrawn before consumption is never credited")
    func withdrawnBeforeConsumption() throws {
        var refreshes = Refreshes()
        let log = OpenCastTabRootView.TabEvaluationLog()
        let upNext = try #require(refreshes.observe([.upNext]).added.first)
        _ = refreshes.observe([])

        // The helper reads what the state holds: nothing, for a withdrawn tab.
        #expect(!log.noteEvaluation(of: .upNext, generation: refreshes.generation(of: upNext.section)))
        #expect(log.refreshCount == 0)
    }
    #endif

    @Test("A selection landing between installation and refresh changes no membership step")
    func selectionBetweenInstallationAndRefresh() {
        var refreshes = Refreshes()
        _ = refreshes.observe([.upNext])
        let step = OpenCastTabRootView.upNextTabStep(
            isOffered: true,
            isShown: true,
            selection: .upNext,
            observedSelection: .inbox,
            isHandoverPending: false
        )
        #expect(step == .none)
    }
}
