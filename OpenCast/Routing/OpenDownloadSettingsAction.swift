import SwiftUI

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
