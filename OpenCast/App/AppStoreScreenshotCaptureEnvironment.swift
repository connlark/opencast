import SwiftUI

extension EnvironmentValues {
    /// True while the App Store screenshot seed is active
    /// (`--opencast-seed-app-store-screenshots`), so views can make
    /// marketing-only accommodations — like the transcript hiding its
    /// floating Play Episode pill to keep the flagged sponsor read
    /// unobstructed.
    @Entry var isAppStoreScreenshotCapture = false
}
