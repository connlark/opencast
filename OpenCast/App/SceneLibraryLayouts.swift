import SwiftUI

/// Lives as long as the scene's root, outliving any one screen; a recreated
/// scene starts afresh.
@Observable
final class SceneLibraryLayouts {
    enum Surface {
        case library
        case inboxGroups
    }

    /// Never cleared: the scene stays foldable when it folds shut.
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
