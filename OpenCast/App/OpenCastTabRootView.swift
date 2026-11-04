import SwiftUI

struct OpenCastTabRootView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge
    /// The scene's fold mark as the root layer publishes it; nil until it
    /// does.
    @Environment(SceneLibraryLayouts.self) private var inheritedSceneLayouts: SceneLibraryLayouts?

    @State private var isSearchPresented = false
    @State private var showsPlaylistsTab = false
    /// The inputs `updatePlaylistsTab` last observed, kept as state so its
    /// deferred update reads them as they are when it runs.
    @State private var playlistsTabHasRail = false
    @State private var playlistsTabSizeClass: UserInterfaceSizeClass?
    /// Set once this scene shows a rail, and never cleared.
    @State private var sceneHasShownRail = false
    @State private var showsUpNextTab = false
    /// Counts the steps that handed a selected Up Next to the Library. Its
    /// observer acknowledges each one after the update that carried it (a
    /// count always changes, so the acknowledgement cannot be lost) and only
    /// then schedules the next step; until then no step runs.
    @State private var upNextHandoverCount = 0
    @State private var acknowledgedUpNextHandoverCount = 0
    /// The selection as its observer last saw it, i.e. as it has landed in
    /// an update. A withdrawal waits until the live selection has landed,
    /// so it never shares an update with a selection change.
    @State private var observedSelection: AppSection?
    /// The size class `updateUpNextTab` last observed, kept as state so its
    /// deferred update reads it as it is when it runs.
    @State private var upNextTabSizeClass: UserInterfaceSizeClass?
    @State private var accessoryGeometryStore = TabAccessoryGeometryStore()
    /// The window as the two-pane roots' reader last reported it.
    @State private var rootWindow = TwoPaneRootWindow.unmeasured
    /// `TwoPaneRootRule`'s answer for the window and the fold latch: the
    /// container the Library and Inbox roots use.
    @State private var rootContainer = TwoPaneRootContainer.stack

    @Binding var selectedTab: AppSection
    @Binding var navigationPaths: AppNavigationPaths
    let onAdd: () -> Void
    let onOpenUpNext: () -> Void
    let onPresentNowPlaying: () -> Void

    var body: some View {
        ZStack {
            // A sibling of the tab view, above every tab's container, so the
            // two-pane rule reads the window without Now Playing open.
            TwoPaneRootWindowReader { window in
                rootWindow = window
            }
            tabView
        }
        .onChange(of: rootWindow, initial: true) {
            updateRootContainer()
        }
        .onChange(of: inheritedSceneLayouts?.isFoldable == true) {
            updateRootContainer()
            // The latch can arrive without a size-class change.
            updateUpNextTab(horizontalSizeClass: horizontalSizeClass)
        }
        .onChange(of: upNextHandoverCount) { _, count in
            // The update that carried the handover has landed.
            acknowledgedUpNextHandoverCount = count
            scheduleUpNextTabStep()
        }
    }

    private var tabView: some View {
        TabView(selection: $selectedTab) {
            Tab(AppSection.library.title, systemImage: AppSection.library.systemImage, value: AppSection.library) {
                TwoPaneRoot(
                    section: .library,
                    container: $rootContainer,
                    path: $navigationPaths[.library],
                    placeholder: .library,
                    openFromRoot: openFromRoot(on: .library),
                    onOpenEpisode: openEpisode(on: .library),
                    onOpenPlaylist: openPlaylist(on: .library)
                ) {
                    LibraryView(
                        onAdd: onAdd,
                        onOpenUpNext: openUpNext,
                        onOpenPlaylist: { openFromRoot(on: .library)(.playlistDetail(id: $0)) },
                        onOpenNotes: { openFromRoot(on: .library)(.notes) }
                    )
                }
                .publishesActiveTabBarPlacement()
            }

            // `defaultVisibility(.hidden, for: .tabBar)` never leaves the compact
            // bar on iOS 27 (six tabs fold Settings and Search into More), so the
            // tab exists only where the bar has room for it: regular width, a
            // rail, or a scene already known to fold (`offersPlaylistsTab`);
            // `updatePlaylistsTab` explains why that switch is deferred.
            if showsPlaylistsTab {
                Tab(
                    AppSection.playlists.title,
                    systemImage: AppSection.playlists.systemImage,
                    value: AppSection.playlists
                ) {
                    NavigationStack(path: $navigationPaths[.playlists]) {
                        PlaylistsView(onOpenPlaylist: openPlaylist(on: .playlists))
                            .withOpenCastDestinations(
                                onOpenEpisode: openEpisode(on: .playlists),
                                onOpenPlaylist: openPlaylist(on: .playlists)
                            )
                    }
                    .publishesActiveTabBarPlacement()
                }
            }

            // The queue as a section on the inner display only
            // (`offersUpNextTab`); inserted and withdrawn by
            // `updateUpNextTab`'s deferred update, as Playlists is.
            if showsUpNextTab {
                Tab(AppSection.upNext.title, systemImage: AppSection.upNext.systemImage, value: AppSection.upNext) {
                    TwoPaneRoot(
                        section: .upNext,
                        container: $rootContainer,
                        path: $navigationPaths[.upNext],
                        placeholder: .upNext,
                        openFromRoot: openFromRoot(on: .upNext),
                        onOpenEpisode: openEpisode(on: .upNext),
                        onOpenPlaylist: openPlaylist(on: .upNext)
                    ) {
                        UpNextRootContent(
                            onOpenEpisode: { openFromRoot(on: .upNext)(UpNextRootContent.route(forQueuedEpisode: $0)) }
                        )
                    }
                    .publishesActiveTabBarPlacement()
                }
            }

            Tab(AppSection.inbox.title, systemImage: AppSection.inbox.systemImage, value: AppSection.inbox) {
                TwoPaneRoot(
                    section: .inbox,
                    container: $rootContainer,
                    path: $navigationPaths[.inbox],
                    placeholder: .inbox,
                    openFromRoot: openFromRoot(on: .inbox),
                    onOpenEpisode: openEpisode(on: .inbox),
                    // The Inbox's destinations open no playlist (as before).
                    onOpenPlaylist: { _ in }
                ) {
                    InboxView(
                        onAdd: onAdd,
                        onOpenEpisode: { openFromRoot(on: .inbox)(.episodeDetail(id: $0)) },
                        onOpenAdDetectionQueue: { openFromRoot(on: .inbox)(.adDetectionQueue) }
                    )
                }
                .publishesActiveTabBarPlacement()
            }

            Tab(
                AppSection.downloads.title,
                systemImage: AppSection.downloads.systemImage,
                value: AppSection.downloads
            ) {
                NavigationStack(path: $navigationPaths[.downloads]) {
                    DownloadsView(onOpenEpisode: openEpisode(on: .downloads))
                    .withOpenCastDestinations(
                        onOpenEpisode: openEpisode(on: .downloads)
                    )
                }
                .publishesActiveTabBarPlacement()
            }
            .badge(appModel.downloads.activeDownloadCount)

            Tab(AppSection.settings.title, systemImage: AppSection.settings.systemImage, value: AppSection.settings) {
                NavigationStack(path: $navigationPaths[.settings]) {
                    SettingsView()
                        .withOpenCastDestinations()
                }
                .publishesActiveTabBarPlacement()
            }

            Tab(
                AppSection.search.title,
                systemImage: AppSection.search.systemImage,
                value: AppSection.search,
                role: .search
            ) {
                NavigationStack(path: $navigationPaths[.search]) {
                    SearchView(
                        directoryService: appModel.podcastDirectoryService,
                        directoryResolver: appModel.podcastDirectoryResolver,
                        isSearchPresented: $isSearchPresented,
                        onOpenEpisode: openEpisode(on: .search),
                        onOpenPodcast: { feedURL in
                            navigationPaths[.search].append(.podcastDetail(feedURL: feedURL))
                        }
                    )
                    .withOpenCastDestinations(
                        onOpenEpisode: openEpisode(on: .search)
                    )
                }
                .publishesActiveTabBarPlacement()
            }
        }
        .environment(\.openDownloadSettings, OpenDownloadSettingsAction(perform: openDownloadSettings))
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(tabBarMinimizeBehavior)
        .tabViewBottomAccessory(isEnabled: showsTabAccessory) {
            tabAccessory
                .reportsTabAccessoryGeometry(updateAccessoryGeometry)
        }
        .environment(accessoryGeometryStore)
        .sensoryFeedback(.success, trigger: appModel.library.subscriptionAddedToken)
        .sensoryFeedback(trigger: appModel.library.refreshCompletedToken) { _, _ in
            appModel.library.lastRefreshWasOffline ? .warning : .success
        }
        .onChange(of: selectedTab, initial: true) { _, selectedTab in
            isSearchPresented = selectedTab == .search
            leavePlaylistsTabIfCompact()
            observedSelection = selectedTab
            scheduleUpNextTabStep()
        }
        .onChange(of: horizontalSizeClass, initial: true) { _, sizeClass in
            updatePlaylistsTab(horizontalSizeClass: sizeClass, hasRail: toolbarVerticalEdge != nil)
            updateUpNextTab(horizontalSizeClass: sizeClass)
        }
        .onChange(of: toolbarVerticalEdge, initial: true) { _, edge in
            updatePlaylistsTab(horizontalSizeClass: horizontalSizeClass, hasRail: edge != nil)
        }
        .onChange(of: showsTabAccessory, initial: true) { _, isShown in
            accessoryGeometryStore.isShown = isShown
            if !isShown {
                accessoryGeometryStore.report = nil
            }
        }
        .focusedSceneValue(\.openCastCommandActions, commandActions)
    }

    /// Playlists is offered at regular width and wherever the system shows a
    /// rail (`toolbarVerticalEdge` non-nil: the iPhone Duo's outer display and
    /// its landscape-shaped inner poses), which holds all six sections. Only
    /// a compact bottom bar withholds it: six tabs would fold Settings and
    /// Search into More. A foldable scene (one that has shown a rail or
    /// reported a fold) offers it in every pose, so it keeps the tab through
    /// what a fold passes on the way: between Closed and the inner display
    /// the window reads compact with no rail for a fifth of a second or so.
    nonisolated static func offersPlaylistsTab(
        hasRail: Bool,
        horizontalSizeClass: UserInterfaceSizeClass?,
        isFoldableScene: Bool
    ) -> Bool {
        hasRail || horizontalSizeClass == .regular || isFoldableScene
    }

    /// A size-class or rail change reaches SwiftUI inside UIKit's trait
    /// transition, and rebuilding the tab set there aborts in
    /// UITabBarController; the next update is safe. Both inputs are recorded
    /// on every change, and the deferred update decides from them as they
    /// are when it runs, never from the ones that scheduled it.
    private func updatePlaylistsTab(horizontalSizeClass: UserInterfaceSizeClass?, hasRail: Bool) {
        playlistsTabSizeClass = horizontalSizeClass
        playlistsTabHasRail = hasRail
        if hasRail {
            sceneHasShownRail = true
        }
        guard showsPlaylistsTab != isPlaylistsTabOffered else {
            return
        }
        Task { @MainActor in
            showsPlaylistsTab = isPlaylistsTabOffered
            leavePlaylistsTabIfCompact()
        }
    }

    private var isPlaylistsTabOffered: Bool {
        Self.offersPlaylistsTab(
            hasRail: playlistsTabHasRail,
            horizontalSizeClass: playlistsTabSizeClass,
            isFoldableScene: sceneHasShownRail || inheritedSceneLayouts?.isFoldable == true
        )
    }

    /// Where the tab is withheld (compact width with no rail: an iPhone, a
    /// compact iPad window), a selected Playlists tab hands over to the
    /// Library, whose Playlists row reaches the same screen. A foldable scene
    /// offers the tab throughout, so a fold never hands over.
    /// `navigationPaths[.playlists]` is kept: when the tab is offered again
    /// its path is intact, and it is not reselected.
    private func leavePlaylistsTabIfCompact() {
        if selectedTab == .playlists, !isPlaylistsTabOffered {
            selectedTab = .library
        }
    }

    /// Up Next is a section only where the scene has reported a fold (the
    /// division-derived latch) and the width is regular: the iPhone Duo's
    /// inner display in every open pose. Never in Closed, never on another
    /// iPhone (no fold), never on an iPad (no fold); a rail is not the signal.
    nonisolated static func offersUpNextTab(
        isFoldableScene: Bool,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        isFoldableScene && horizontalSizeClass == .regular
    }

    /// Records the size class and schedules the tab set's next step.
    private func updateUpNextTab(horizontalSizeClass: UserInterfaceSizeClass?) {
        upNextTabSizeClass = horizontalSizeClass
        scheduleUpNextTabStep()
    }

    /// Applies `upNextTabStep` on the next update, as `updatePlaylistsTab`
    /// does: a tab set rebuilt inside UIKit's trait transition aborts. The
    /// task decides from the inputs and the selection as they are when it
    /// runs, never from the ones that scheduled it, so redundant tasks do
    /// nothing. Withdrawing a selected Up Next takes two updates: this one
    /// hands the selection to the Library; the handover count's observer then
    /// acknowledges it and schedules the next step (the withdrawal, or
    /// another handover if Up Next was selected again meanwhile), and until
    /// it does no queued task installs or withdraws anything.
    private func scheduleUpNextTabStep() {
        // Also when the tab set already matches eligibility but Up Next is
        // selected without its tab (a selection that raced the withdrawal):
        // the step hands it to the Library.
        guard showsUpNextTab != isUpNextTabOffered || (selectedTab == .upNext && !showsUpNextTab) else {
            return
        }
        Task { @MainActor in
            switch Self.upNextTabStep(
                isOffered: isUpNextTabOffered,
                isShown: showsUpNextTab,
                selection: selectedTab,
                observedSelection: observedSelection,
                isHandoverPending: upNextHandoverCount != acknowledgedUpNextHandoverCount
            ) {
            case .none:
                break
            case .awaitSelectionUpdate:
                // A selection written since the last update has not landed.
                // Its observer schedules the next step when it does; should
                // it be written back before an update (no observation), this
                // look a settle later decides again. Not a spin: each look
                // waits longer than a frame.
                try? await Task.sleep(for: Self.selectionSettle)
                scheduleUpNextTabStep()
            case .handOverToLibrary:
                // Closed: the explicit exception to keeping the visible page.
                // Both paths are kept; reopening does not reselect Up Next.
                upNextHandoverCount += 1
                selectedTab = .library
            case .install:
                showsUpNextTab = true
            case .withdraw:
                showsUpNextTab = false
            }
        }
    }

    /// Longer than a frame: a selection written before it has landed in an
    /// update by the time it ends.
    static let selectionSettle: Duration = .milliseconds(50)

    /// One step of the Up Next tab set toward the current eligibility.
    enum UpNextTabStep: Equatable {
        case none
        /// The live selection has not landed in an update yet: look again
        /// once it has.
        case awaitSelectionUpdate
        /// Up Next is selected and no longer offered: select the Library
        /// first, in its own update.
        case handOverToLibrary
        case install
        /// Up Next is not selected and no longer offered.
        case withdraw
    }

    static func upNextTabStep(
        isOffered: Bool,
        isShown: Bool,
        selection: AppSection,
        observedSelection: AppSection?,
        isHandoverPending: Bool
    ) -> UpNextTabStep {
        guard !isHandoverPending else {
            return .none
        }
        if !isShown, !isOffered, selection == .upNext {
            // Selected without its tab: never left there.
            return .handOverToLibrary
        }
        guard isShown != isOffered else {
            return .none
        }
        if isOffered {
            return .install
        }
        if selection == .upNext {
            return .handOverToLibrary
        }
        // Withdraw only once the selection that is not Up Next has landed.
        return selection == observedSelection ? .withdraw : .awaitSelectionUpdate
    }

    /// What the Library's Up Next row and the accessory's queue action do.
    enum UpNextOpening: Equatable {
        case selectTab
        case presentSheet
    }

    /// The tab only when it is installed and offered by the current inputs;
    /// otherwise the existing sheet.
    static func upNextOpening(isTabInstalled: Bool, isTabOffered: Bool) -> UpNextOpening {
        isTabInstalled && isTabOffered ? .selectTab : .presentSheet
    }

    private var isUpNextTabOffered: Bool {
        Self.offersUpNextTab(
            isFoldableScene: inheritedSceneLayouts?.isFoldable == true,
            horizontalSizeClass: upNextTabSizeClass
        )
    }

    /// The Library's Up Next row and the accessory's queue action: the Up
    /// Next tab where it is installed and offered (the inner display), the
    /// existing queue sheet everywhere else. The card's own Up Next is not
    /// routed here.
    private func openUpNext() {
        switch Self.upNextOpening(isTabInstalled: showsUpNextTab, isTabOffered: isUpNextTabOffered) {
        case .selectTab:
            selectedTab = .upNext
        case .presentSheet:
            onOpenUpNext()
        }
    }

    private func openDownloadSettings() {
        selectedTab = .downloads
        navigationPaths[.downloads] = [.downloadSettings]
    }

    /// The rule's container for the current window and latch; every change
    /// is logged with the inputs that made it.
    private func updateRootContainer() {
        let isFoldableScene = inheritedSceneLayouts?.isFoldable == true
        let container = TwoPaneRootRule.container(
            pose: rootWindow.pose,
            isFoldableScene: isFoldableScene,
            windowSize: rootWindow.size
        )
        TwoPaneRootLog.inputs(rootWindow, isFoldableScene: isFoldableScene, container: container)
        guard container != rootContainer else {
            return
        }
        TwoPaneRootLog.containerChange(from: rootContainer, to: container)
        rootContainer = container
    }

    /// A route opened from a two-pane root's own content (its rows, tiles,
    /// collection entries, callbacks and context menus): the detail's new
    /// root in the split, a push in the stack (`TwoPaneRootPath`).
    private func openFromRoot(on section: AppSection) -> (AppRoute) -> Void {
        { route in
            navigationPaths[section] = TwoPaneRootPath.openingFromRoot(
                route,
                in: navigationPaths[section],
                container: rootContainer
            )
        }
    }

    private func openEpisode(on section: AppSection) -> (String) -> Void {
        { episodeID in
            navigationPaths[section].append(.episodeDetail(id: episodeID))
        }
    }

    private func openPlaylist(on section: AppSection) -> (String) -> Void {
        { playlistID in
            navigationPaths[section].append(.playlistDetail(id: playlistID))
        }
    }

    private var showsTabAccessory: Bool {
        appModel.playback.currentEpisode != nil || appModel.showsUpNextAccessory
    }

    private func updateAccessoryGeometry(_ geometry: TabAccessoryGeometry) {
        accessoryGeometryStore.report = geometry
    }

    /// One system accessory, two contents: the mini player while an episode
    /// is loaded, otherwise the queue head with a play control.
    @ViewBuilder
    private var tabAccessory: some View {
        if appModel.playback.currentEpisode != nil {
            MiniPlayerView(
                onExpand: onPresentNowPlaying
            )
        } else {
            UpNextAccessoryView(
                onOpenQueue: openUpNext
            )
        }
    }

    private var commandActions: OpenCastCommandActions {
        OpenCastCommandActions.make(
            playback: appModel.playback,
            focusSearch: {
                selectedTab = .search
                isSearchPresented = true
            }
        )
    }

    /// Off unless chosen in Look & Feel: minimizing moves the bottom accessory
    /// inline, and every minimize or expand re-lays out the navigation stack
    /// inside the scroll callback, 40–55 ms main-thread stalls on an iPhone
    /// SE, felt as a stutter when a scroll starts or reaches the top.
    private var tabBarMinimizeBehavior: TabBarMinimizeBehavior {
        appModel.appearanceSettings.minimizesTabBarOnScroll && selectedTab != .settings ? .onScrollDown : .never
    }
}
