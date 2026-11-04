import SwiftUI

extension EnvironmentValues {
    /// The section bar's placement for a tab's screens, published from
    /// inside each tab's content; nil outside the tab view or where the
    /// system reports a placement `ActiveTabBarPlacement` does not model.
    @Entry var activeTabBarPlacement: ActiveTabBarPlacement?
}
