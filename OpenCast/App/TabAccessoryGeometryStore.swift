import SwiftUI

/// Put in the environment once, so a new report (a rotation, a minimize)
/// invalidates only the scroll views that read it, never the tab view.
@Observable
final class TabAccessoryGeometryStore {
    var isShown = false
    var report: TabAccessoryGeometry?

    var geometry: TabAccessoryGeometry {
        guard isShown else {
            return .absent
        }
        return report ?? .undefined(frame: nil)
    }
}
