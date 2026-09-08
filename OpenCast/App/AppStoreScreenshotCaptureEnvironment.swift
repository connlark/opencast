import SwiftUI

extension EnvironmentValues {
    /// True while the App Store screenshot seed is active
    /// (`--opencast-seed-app-store-screenshots`), so views can make
    /// marketing-only accommodations — like the transcript hiding its
    /// floating Play Episode pill to keep the flagged sponsor read
    /// unobstructed.
    @Entry var isAppStoreScreenshotCapture = false

    /// Keeps Now Playing's "Skipped promo" pill on screen for the ad-skip
    /// hero shot (`--opencast-pin-app-store-autoskip-pill`).
    @Entry var pinsAppStoreAutoSkipPill = false

    /// Seeds the Sound Lab reveal at a fixed progress so a mid-slide pose can
    /// be captured as a still (`OPENCAST_PIN_APP_STORE_SOUND_LAB_REVEAL`).
    @Entry var appStoreSoundLabRevealProgress: Double?
}
