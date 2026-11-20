#if DEBUG
import OSLog
#endif
import SwiftUI

struct OpenCastTabRootView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// nil until the root layer publishes it.
    @Environment(SceneLibraryLayouts.self) private var inheritedSceneLayouts: SceneLibraryLayouts?

    @State private var isSearchPresented = false
    @State private var showsPlaylistsTab = false
    /// Kept as state so the deferred update reads it as it is when it runs.
    @State private var playlistsTabSizeClass: UserInterfaceSizeClass?
    @State private var showsUpNextTab: Bool
    @State private var showsSettingsTab: Bool
    /// Bumped by each handover to the Library. Its observer acknowledges it once
    /// the update that carried it lands (a count always changes, so no
    /// acknowledgement is lost); until then no step runs.
    @State private var handoverCount = 0
    @State private var acknowledgedHandoverCount = 0
    /// The selection as it has landed in an update. A withdrawal waits for the
    /// live selection to land, so it never shares an update with a selection change.
    @State private var observedSelection: AppSection?
    /// Kept as state so the deferred update reads it as it is when it runs.
    @State private var upNextTabSizeClass: UserInterfaceSizeClass?
    @State private var accessoryGeometryStore = TabAccessoryGeometryStore()
    @State private var rootWindow = TwoPaneRootWindow.unmeasured
    @State private var rootContainer = TwoPaneRootContainer.stack
    @State private var tabRefreshes = TabRefreshes()
    #if DEBUG
    @State private var tabLabelFormTransitions = 0
    @State private var tabEvaluationLog = TabEvaluationLog()
    #endif

    @Binding var selectedTab: AppSection
    @Binding var navigationPaths: AppNavigationPaths
    let onAdd: () -> Void
    let onOpenUpNext: () -> Void
    let onPresentNowPlaying: () -> Void

    /// `upNextTabSwitch` seeds only the first tab set; later flips go through
    /// the deferred steps.
    init(
        selectedTab: Binding<AppSection>,
        navigationPaths: Binding<AppNavigationPaths>,
        upNextTabSwitch: Bool,
        onAdd: @escaping () -> Void,
        onOpenUpNext: @escaping () -> Void,
        onPresentNowPlaying: @escaping () -> Void
    ) {
        _selectedTab = selectedTab
        _navigationPaths = navigationPaths
        _showsUpNextTab = State(initialValue: upNextTabSwitch)
        _showsSettingsTab = State(initialValue: !upNextTabSwitch)
        self.onAdd = onAdd
        self.onOpenUpNext = onOpenUpNext
        self.onPresentNowPlaying = onPresentNowPlaying
    }

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
        .onChange(of: appModel.appearanceSettings.showsUpNextTab) {
            scheduleTabSetStep()
        }
        .onChange(of: handoverCount) { _, count in
            // The update that carried the handover has landed.
            acknowledgedHandoverCount = count
            scheduleTabSetStep()
        }
        .onChange(of: installedTabSections, initial: true) { _, installed in
            updateTabInstallations(installed)
        }
        #if DEBUG
        .onChange(of: tabLabelForm, initial: true) { oldForm, form in
            if form != oldForm {
                tabLabelFormTransitions += 1
                logSectionForms(form)
            }
            Self.formLogger.notice(
                "tab-root form \(form.rawValue, privacy: .public) transition \(tabLabelFormTransitions, privacy: .public)"
            )
        }
        #endif
    }

    private var tabView: some View {
        TabView(selection: $selectedTab) {
            sectionTab(.library) {
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
                        onOpenPlaylists: { openFromRoot(on: .library)(.playlists) },
                        onOpenUpNext: openUpNext,
                        onOpenPlaylist: { openFromRoot(on: .library)(.playlistDetail(id: $0)) },
                        onOpenNotes: { openFromRoot(on: .library)(.notes) },
                        onOpenSettings: showsSettingsTab ? nil : { openFromRoot(on: .library)(.settings(.hub)) }
                    )
                }
                .publishesActiveTabBarPlacement()
            }

            // `defaultVisibility(.hidden, for: .tabBar)` never leaves the compact
            // bar on iOS 27 (six tabs fold Settings and Search into More), so the
            // tab is inserted only where the bar has room for it.
            if showsPlaylistsTab {
                sectionTab(.playlists) {
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

            if showsUpNextTab {
                sectionTab(.upNext) {
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
                            rowAction: inheritedSceneLayouts?.isFoldable == true ? .openEpisode : .play,
                            onOpenEpisode: { openFromRoot(on: .upNext)(UpNextRootContent.route(forQueuedEpisode: $0)) }
                        )
                    }
                    .publishesActiveTabBarPlacement()
                }
            }

            sectionTab(.inbox) {
                TwoPaneRoot(
                    section: .inbox,
                    container: $rootContainer,
                    path: $navigationPaths[.inbox],
                    placeholder: .inbox,
                    openFromRoot: openFromRoot(on: .inbox),
                    onOpenEpisode: openEpisode(on: .inbox),
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

            sectionTab(.downloads) {
                NavigationStack(path: $navigationPaths[.downloads]) {
                    DownloadsView(
                        onOpenEpisode: openEpisode(on: .downloads),
                        onOpenDownloadSettings: { navigationPaths[.downloads].append(.downloadSettings) }
                    )
                    .withOpenCastDestinations(
                        onOpenEpisode: openEpisode(on: .downloads)
                    )
                }
                .publishesActiveTabBarPlacement()
            }
            .badge(appModel.downloads.activeDownloadCount)

            if showsSettingsTab {
                sectionTab(.settings) {
                    NavigationStack(path: $navigationPaths[.settings]) {
                        SettingsView()
                            .withOpenCastDestinations()
                    }
                    .publishesActiveTabBarPlacement()
                }
            }

            sectionTab(.search, role: .search) {
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
            scheduleTabSetStep()
        }
        .onChange(of: horizontalSizeClass, initial: true) { _, sizeClass in
            updatePlaylistsTab(horizontalSizeClass: sizeClass)
            updateUpNextTab(horizontalSizeClass: sizeClass)
        }
        .onChange(of: showsTabAccessory, initial: true) { _, isShown in
            accessoryGeometryStore.isShown = isShown
            if !isShown {
                accessoryGeometryStore.report = nil
            }
        }
        .focusedSceneValue(\.openCastCommandActions, commandActions)
    }

    /// One stable declaration whose title alone follows the form, so the fold
    /// latch updates the tabs in place and replaces no content.
    private func sectionTab<Content: View>(
        _ section: AppSection,
        role: TabRole? = nil,
        @ViewBuilder content: () -> Content
    ) -> some TabContent<AppSection> {
        // Read in every build: recording a generation is what re-evaluates
        // the declarations. Never written here, and never the tab's identity.
        let generation = tabRefreshes.generation(of: section)
        #if DEBUG
        tabEvaluationLog.noteEvaluation(of: section, generation: generation)
        #else
        _ = generation
        #endif
        return Tab(
            tabLabelForm == .iconOnly ? "" : section.title,
            systemImage: section.systemImage,
            value: section,
            role: role,
            content: content
        )
        .accessibilityLabel(Text(section.title), isEnabled: tabLabelForm == .iconOnly)
    }

    private var installedTabSections: Set<AppSection> {
        var sections: Set<AppSection> = [.library, .inbox, .downloads, .search]
        if showsSettingsTab {
            sections.insert(.settings)
        }
        if showsPlaylistsTab {
            sections.insert(.playlists)
        }
        if showsUpNextTab {
            sections.insert(.upNext)
        }
        return sections
    }

    /// A tab inserted with an empty title keeps its symbol's description as its
    /// label until the declarations are next evaluated; recording a generation
    /// the helper reads forces that evaluation, after the inserting update.
    private func updateTabInstallations(_ installed: Set<AppSection>) {
        let change = tabRefreshes.observe(installed)
        #if DEBUG
        for installation in change.withdrawn {
            logTabInstallation(installation, "withdrawn")
        }
        for installation in change.added {
            logTabInstallation(installation, "installed, generation recorded")
        }
        #else
        _ = change
        #endif
    }

    /// Generations come from an allocator never reset, so a reinstallation gets
    /// its own. Membership alone drives it: a tab awaiting its handover keeps
    /// its generation.
    struct TabRefreshes: Equatable {
        struct Installation: Equatable {
            let section: AppSection
            let generation: Int
        }

        private var lastGeneration = 0
        private var generations: [AppSection: Int] = [:]

        mutating func observe(_ installed: Set<AppSection>) -> (added: [Installation], withdrawn: [Installation]) {
            var added: [Installation] = []
            var withdrawn: [Installation] = []
            for section in AppSection.allCases {
                if let generation = generations[section], !installed.contains(section) {
                    withdrawn.append(Installation(section: section, generation: generation))
                    generations[section] = nil
                } else if generations[section] == nil, installed.contains(section) {
                    lastGeneration += 1
                    generations[section] = lastGeneration
                    added.append(Installation(section: section, generation: lastGeneration))
                }
            }
            return (added, withdrawn)
        }

        func generation(of section: AppSection) -> Int? {
            generations[section]
        }
    }

    /// Seven titled tabs do not fit the iPhone Duo's bottom bar.
    private var tabLabelForm: TabLabelForm {
        inheritedSceneLayouts?.isFoldable == true ? .iconOnly : .titled
    }

    #if DEBUG
    private static let formLogger = Logger(subsystem: "com.connor.opencast", category: "TwoPaneRoot")

    private func logTabInstallation(_ installation: TabRefreshes.Installation, _ event: String) {
        Self.formLogger.notice(
            "tab-root section \(installation.section.rawValue, privacy: .public) gen \(installation.generation, privacy: .public) \(event, privacy: .public)"
        )
    }

    private func logSectionForms(_ form: TabLabelForm) {
        let installed = installedTabSections
        for section in AppSection.allCases where installed.contains(section) {
            let generation = tabRefreshes.generation(of: section).map(String.init) ?? "none"
            Self.formLogger.notice(
                "tab-root section \(section.rawValue, privacy: .public) gen \(generation, privacy: .public) form \(form.rawValue, privacy: .public)"
            )
        }
    }

    /// A plain object, not observable: noting an evaluation during a body
    /// build must invalidate nothing.
    final class TabEvaluationLog {
        private var credited: Set<Int> = []

        @discardableResult
        func noteEvaluation(of section: AppSection, generation: Int?) -> Bool {
            guard let generation, credited.insert(generation).inserted else {
                return false
            }
            let count = credited.count
            OpenCastTabRootView.formLogger.notice(
                "tab-root section \(section.rawValue, privacy: .public) gen \(generation, privacy: .public) refresh \(count, privacy: .public)"
            )
            return true
        }
    }
    #endif

    /// Compact width withholds it (the Library's Playlists row reaches the same
    /// screen): a bottom bar would fold into More, and the Duo's Closed rail has
    /// no room for six tabs beside two toolbar buttons and a Live Activity.
    nonisolated static func offersPlaylistsTab(horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        horizontalSizeClass == .regular
    }

    /// A size-class change arrives inside UIKit's trait transition, where
    /// rebuilding the tab set aborts in UITabBarController, so the update is
    /// deferred and decides from the size class as it is when it runs.
    private func updatePlaylistsTab(horizontalSizeClass: UserInterfaceSizeClass?) {
        playlistsTabSizeClass = horizontalSizeClass
        guard showsPlaylistsTab != isPlaylistsTabOffered else {
            return
        }
        Task { @MainActor in
            showsPlaylistsTab = isPlaylistsTabOffered
            leavePlaylistsTabIfCompact()
        }
    }

    private var isPlaylistsTabOffered: Bool {
        Self.offersPlaylistsTab(horizontalSizeClass: playlistsTabSizeClass)
    }

    /// `navigationPaths[.playlists]` is kept, so the path is intact when the tab
    /// is offered again.
    private func leavePlaylistsTabIfCompact() {
        if selectedTab == .playlists, !isPlaylistsTabOffered {
            selectedTab = .library
        }
    }

    nonisolated static func offersUpNextTab(
        isFoldableScene: Bool,
        horizontalSizeClass: UserInterfaceSizeClass?,
        isSwitchOn: Bool = false
    ) -> Bool {
        isSwitchOn || (isFoldableScene && horizontalSizeClass == .regular)
    }

    nonisolated static func offersSettingsTab(isUpNextTabSwitchOn: Bool) -> Bool {
        !isUpNextTabSwitchOn
    }

    private func updateUpNextTab(horizontalSizeClass: UserInterfaceSizeClass?) {
        upNextTabSizeClass = horizontalSizeClass
        scheduleTabSetStep()
    }

    /// Runs on the next update, deciding from the state as it is then.
    /// Withdrawing a selected tab takes two updates:
    ///   update 1: selectedTab = .library, handoverCount += 1
    ///   update 2: the count's observer acknowledges; the next step withdraws
    /// Until the acknowledgement, no queued step installs or withdraws.
    private func scheduleTabSetStep() {
        // Also a tab selected without being installed (a selection that raced
        // its withdrawal): the step hands it to the Library.
        guard showsUpNextTab != isUpNextTabOffered
            || showsSettingsTab != isSettingsTabOffered
            || (selectedTab == .upNext && !showsUpNextTab)
            || (selectedTab == .settings && !showsSettingsTab)
        else {
            return
        }
        Task { @MainActor in
            let isHandoverPending = handoverCount != acknowledgedHandoverCount
            let step = Self.tabSetStep(
                upNext: Self.upNextTabStep(
                    isOffered: isUpNextTabOffered,
                    isShown: showsUpNextTab,
                    selection: selectedTab,
                    observedSelection: observedSelection,
                    isHandoverPending: isHandoverPending
                ),
                settings: Self.settingsTabStep(
                    isOffered: isSettingsTabOffered,
                    isShown: showsSettingsTab,
                    selection: selectedTab,
                    observedSelection: observedSelection,
                    isHandoverPending: isHandoverPending
                )
            )
            let paths = Self.paths(after: step, in: navigationPaths)
            if paths != navigationPaths {
                navigationPaths = paths
            }
            switch step {
            case .none:
                break
            case .awaitSelectionUpdate:
                // A selection written back before it lands triggers no
                // observer, so this look decides again a settle later. Not a
                // spin: each look waits longer than a frame.
                try? await Task.sleep(for: Self.selectionSettle)
                scheduleTabSetStep()
            case .handOverToLibrary:
                handoverCount += 1
                selectedTab = .library
            case .install(let tab):
                setInstalled(tab, true)
            case .withdraw(let tab):
                setInstalled(tab, false)
            case .replace(let withdrawn, let installed):
                setInstalled(withdrawn, false)
                setInstalled(installed, true)
            }
        }
    }

    private func setInstalled(_ tab: ManagedTab, _ isInstalled: Bool) {
        switch tab {
        case .upNext:
            showsUpNextTab = isInstalled
        case .settings:
            showsSettingsTab = isInstalled
        }
    }

    /// Longer than a frame: a selection written before it has landed in an
    /// update by the time it ends.
    static let selectionSettle: Duration = .milliseconds(50)

    enum UpNextTabStep: Equatable {
        case none
        case awaitSelectionUpdate
        case handOverToLibrary
        case install
        case withdraw
    }

    static func upNextTabStep(
        isOffered: Bool,
        isShown: Bool,
        selection: AppSection,
        observedSelection: AppSection?,
        isHandoverPending: Bool
    ) -> UpNextTabStep {
        tabStep(
            of: .upNext,
            isOffered: isOffered,
            isShown: isShown,
            selection: selection,
            observedSelection: observedSelection,
            isHandoverPending: isHandoverPending
        )
    }

    static func settingsTabStep(
        isOffered: Bool,
        isShown: Bool,
        selection: AppSection,
        observedSelection: AppSection?,
        isHandoverPending: Bool
    ) -> UpNextTabStep {
        tabStep(
            of: .settings,
            isOffered: isOffered,
            isShown: isShown,
            selection: selection,
            observedSelection: observedSelection,
            isHandoverPending: isHandoverPending
        )
    }

    private static func tabStep(
        of tab: ManagedTab,
        isOffered: Bool,
        isShown: Bool,
        selection: AppSection,
        observedSelection: AppSection?,
        isHandoverPending: Bool
    ) -> UpNextTabStep {
        guard !isHandoverPending else {
            return .none
        }
        if !isShown, !isOffered, selection == tab.section {
            return .handOverToLibrary
        }
        guard isShown != isOffered else {
            return .none
        }
        if isOffered {
            return .install
        }
        if selection == tab.section {
            return .handOverToLibrary
        }
        return selection == observedSelection ? .withdraw : .awaitSelectionUpdate
    }

    enum ManagedTab: Equatable {
        case upNext
        case settings

        var section: AppSection {
            switch self {
            case .upNext:
                .upNext
            case .settings:
                .settings
            }
        }
    }

    /// Ordered so no update holds more tabs than the set before or after the
    /// transition.
    enum TabSetStep: Equatable {
        case none
        case awaitSelectionUpdate
        case handOverToLibrary(from: ManagedTab)
        case install(ManagedTab)
        case withdraw(ManagedTab)
        /// One update for both: on iOS 27.2 the bar goes from one five-tab set
        /// to the other with no sixth tab and no More in any frame.
        case replace(ManagedTab, with: ManagedTab)
    }

    static func tabSetStep(upNext: UpNextTabStep, settings: UpNextTabStep) -> TabSetStep {
        if settings == .handOverToLibrary {
            return .handOverToLibrary(from: .settings)
        }
        if upNext == .handOverToLibrary {
            return .handOverToLibrary(from: .upNext)
        }
        if upNext == .awaitSelectionUpdate || settings == .awaitSelectionUpdate {
            return .awaitSelectionUpdate
        }
        switch (upNext, settings) {
        case (.withdraw, .install):
            return .replace(.upNext, with: .settings)
        case (.install, .withdraw):
            return .replace(.settings, with: .upNext)
        case (.withdraw, _):
            return .withdraw(.upNext)
        case (_, .withdraw):
            return .withdraw(.settings)
        case (.install, _):
            return .install(.upNext)
        case (_, .install):
            return .install(.settings)
        default:
            return .none
        }
    }

    /// A Settings tab withdrawn without a handover drops its path, so one that
    /// returns weeks later never reopens on an old screen. Up Next keeps its path.
    static func paths(after step: TabSetStep, in paths: AppNavigationPaths) -> AppNavigationPaths {
        var paths = paths
        switch step {
        case .handOverToLibrary(from: .settings):
            paths[.library] = SettingsOpening.libraryPath(continuing: paths[.settings])
            paths[.settings] = []
        case .withdraw(.settings), .replace(.settings, with: _):
            if !paths[.settings].isEmpty {
                paths[.settings] = []
            }
        default:
            break
        }
        return paths
    }

    enum UpNextOpening: Equatable {
        case selectTab
        case presentSheet
    }

    static func upNextOpening(isTabInstalled: Bool, isTabOffered: Bool) -> UpNextOpening {
        isTabInstalled && isTabOffered ? .selectTab : .presentSheet
    }

    private var isUpNextTabOffered: Bool {
        Self.offersUpNextTab(
            isFoldableScene: inheritedSceneLayouts?.isFoldable == true,
            horizontalSizeClass: upNextTabSizeClass,
            isSwitchOn: appModel.appearanceSettings.showsUpNextTab
        )
    }

    private var isSettingsTabOffered: Bool {
        Self.offersSettingsTab(isUpNextTabSwitchOn: appModel.appearanceSettings.showsUpNextTab)
    }

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

    /// For routes opened from a two-pane root's own content: a new detail root
    /// in the split, a push in the stack.
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

    /// Off by default: every minimize or expand re-lays out the navigation stack
    /// inside the scroll callback, 40 to 55 ms stalls on an iPhone SE.
    private var tabBarMinimizeBehavior: TabBarMinimizeBehavior {
        appModel.appearanceSettings.minimizesTabBarOnScroll && !showsSettingsScreen ? .onScrollDown : .never
    }

    /// The Library's path is read only with the Settings tab withdrawn.
    private var showsSettingsScreen: Bool {
        selectedTab == .settings
            || (!showsSettingsTab && selectedTab == .library && navigationPaths[.library].last?.isSettingsScreen == true)
    }
}
