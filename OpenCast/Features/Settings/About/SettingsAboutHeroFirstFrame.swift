import RealityKit
import SwiftUI

/// Tracks when a `RealityView` has started drawing. Its placeholder goes away
/// when the make closure returns, but the first frame still waits on shader
/// compilation, so the 2D image underneath stays until the scene has ticked.
@Observable
final class SettingsAboutHeroFirstFrame {
    private(set) var hasRendered = false

    @ObservationIgnored private var subscription: EventSubscription?
    @ObservationIgnored private var updateCount = 0

    func watch(_ content: RealityViewCameraContent) {
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            self?.sceneDidUpdate()
        }
    }

    private func sceneDidUpdate() {
        updateCount += 1
        // The first update can precede the first presented frame.
        guard updateCount >= 2 else {
            return
        }
        hasRendered = true
        subscription?.cancel()
        subscription = nil
    }
}
