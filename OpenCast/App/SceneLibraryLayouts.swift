import SwiftUI

/// What one scene remembers about its Library layouts: whether its window
/// has ever reported a fold, and the Automatic family each surface settled
/// on. The root layer owns it in state, so it lives as long as the scene's
/// root and outlives any one screen; a recreated scene starts afresh.
@Observable
final class SceneLibraryLayouts {
    enum Surface {
        case library
        case inboxGroups
    }

    /// Set once the window reports a `.division` region, active or inactive
    /// (the inner display reports the band inactive while flat), and never
    /// cleared: the scene stays foldable when it folds shut.
    private(set) var isFoldable = false
    private var library = AutomaticLibraryLayout()
    private var inboxGroups = AutomaticLibraryLayout()

    func layout(
        of surface: Surface,
        for preference: LibraryLayoutPreference,
        isRegularWidth: Bool
    ) -> LibraryLayout {
        self[surface].layout(for: preference, isRegularWidth: isRegularWidth, isFoldableScene: isFoldable)
    }

    func observe(_ preference: LibraryLayoutPreference, on surface: Surface, isRegularWidth: Bool) {
        self[surface].observe(preference, isRegularWidth: isRegularWidth)
    }

    func markFoldable(ifReported regions: [WindowDivisionRegion]) {
        if !isFoldable, Self.reportsFold(regions) {
            isFoldable = true
        }
    }

    /// Any `.division` region with a positive, finite size counts, active or
    /// not: a flat inner display reports its fold as inactive.
    nonisolated static func reportsFold(_ regions: [WindowDivisionRegion]) -> Bool {
        regions.contains { region in
            WindowDivisionRegion(frame: region.frame, isActive: true).isUsable
        }
    }

    /// The window's `.division` regions including the inactive ones, for
    /// `markFoldable(ifReported:)`.
    static func divisionRegions(in proxy: GeometryProxy) -> [WindowDivisionRegion] {
        proxy.reservedRegions(kind: .division, options: .includeInactive).map(WindowDivisionRegion.init)
    }

    private subscript(surface: Surface) -> AutomaticLibraryLayout {
        get {
            switch surface {
            case .library:
                library
            case .inboxGroups:
                inboxGroups
            }
        }
        set {
            switch surface {
            case .library:
                library = newValue
            case .inboxGroups:
                inboxGroups = newValue
            }
        }
    }
}
