import SwiftUI

extension EnvironmentValues {
    /// nil outside the tab view, or for a placement `ActiveTabBarPlacement`
    /// does not model.
    @Entry var activeTabBarPlacement: ActiveTabBarPlacement?
}
