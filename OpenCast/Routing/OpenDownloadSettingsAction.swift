import SwiftUI

/// Switches to the Downloads tab and opens Download Settings, so a screen
/// in another tab (Settings › Storage) can route to the one home for
/// download settings without owning a navigation path.
struct OpenDownloadSettingsAction {
    let perform: () -> Void

    func callAsFunction() {
        perform()
    }
}

extension EnvironmentValues {
    /// Nil outside the tab root, where there is no Downloads tab to open.
    @Entry var openDownloadSettings: OpenDownloadSettingsAction?
}
