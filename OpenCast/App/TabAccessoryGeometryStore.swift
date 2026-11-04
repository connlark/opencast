import SwiftUI

/// Carries the tab accessory's geometry from the accessory closure to the
/// screens beneath it. The tab root owns it and puts it in the environment
/// once; a new report (a rotation, a minimize) then invalidates only the
/// scroll views that read it, never the tab view.
@Observable
final class TabAccessoryGeometryStore {
    /// Whether the tab root shows an accessory.
    var isShown = false
    /// The accessory's last report from inside its closure.
    var report: TabAccessoryGeometry?

    /// Absent when no accessory is shown; undefined until its first report.
    var geometry: TabAccessoryGeometry {
        guard isShown else {
            return .absent
        }
        return report ?? .undefined(frame: nil)
    }
}
