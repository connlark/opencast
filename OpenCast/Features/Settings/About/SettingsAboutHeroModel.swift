import Foundation
import OSLog
import RealityKit

/// Owns the About hero's loaded RealityKit entities for the life of the About
/// screen, so a `RealityView` that leaves the hierarchy (background, Low
/// Power) re-adds the same stage without touching the file again.
@Observable
final class SettingsAboutHeroModel {
    nonisolated static let resourceName = "OpencastGlassIcon"

    private static let logger = Logger(subsystem: "com.connor.opencast", category: "AboutGlassHero")
    private static let entranceYaw: Float = -20 * .pi / 180

    private(set) var loadState = SettingsAboutHeroLoadState.idle
    private(set) var showsBack = false

    @ObservationIgnored private(set) var stage: Entity?
    @ObservationIgnored private var turntable: Entity?
    @ObservationIgnored private var motion: AnimationPlaybackController?
    @ObservationIgnored private var hasPlayedEntrance = false
    @ObservationIgnored private var dragReleaseOffset: Double?

    func load(bundle: Bundle = .main) async {
        guard loadState == .idle else {
            return
        }
        loadState = .loading
        do {
            let icon = try await Entity(named: Self.resourceName, in: bundle)
            let (stage, turntable) = SettingsAboutHeroScene.makeStage(holding: icon)
            self.stage = stage
            self.turntable = turntable
            loadState = .loaded
        } catch is CancellationError {
            loadState = .idle
        } catch {
            Self.logger.error("About glass hero failed to load: \(error.localizedDescription, privacy: .public)")
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Turns in from a slight angle the first time the model is shown.
    func playEntranceIfNeeded(animated: Bool) {
        guard !hasPlayedEntrance else {
            return
        }
        hasPlayedEntrance = true
        guard animated else {
            return
        }
        turntable?.orientation = Self.rotation(yaw: Self.entranceYaw)
        turn(toYaw: restingYaw, duration: 1.6, timingFunction: .easeOut)
    }

    func toggleFace(animated: Bool) {
        showsBack.toggle()
        turn(toYaw: restingYaw, duration: animated ? 0.9 : 0, timingFunction: .easeInOut)
    }

    /// Follows a horizontal drag live; `releaseOffset` is where the drag
    /// would land given its velocity, which decides the face on release.
    func dragTurn(offset: Double, releaseOffset: Double) {
        motion?.stop()
        motion = nil
        dragReleaseOffset = releaseOffset
        turntable?.orientation = Self.rotation(yaw: restingYaw + Float(offset))
    }

    /// Settles a drag on the nearer face; does nothing when no drag is live.
    func endDragTurn(animated: Bool) {
        guard let releaseOffset = dragReleaseOffset else {
            return
        }
        dragReleaseOffset = nil
        showsBack = SettingsAboutHeroYawGesture.showsBack(afterReleasingAt: releaseOffset, showingBack: showsBack)
        turn(toYaw: restingYaw, duration: animated ? 0.35 : 0, timingFunction: .easeOut)
    }

    private var restingYaw: Float {
        showsBack ? .pi : 0
    }

    private func turn(toYaw yaw: Float, duration: TimeInterval, timingFunction: AnimationTimingFunction) {
        guard let turntable else {
            return
        }
        motion?.stop()
        motion = nil
        var target = turntable.transform
        target.rotation = Self.rotation(yaw: yaw)
        guard duration > 0, turntable.scene != nil else {
            turntable.transform = target
            return
        }
        motion = turntable.move(to: target, relativeTo: turntable.parent, duration: duration, timingFunction: timingFunction)
    }

    private static func rotation(yaw: Float) -> simd_quatf {
        simd_quatf(angle: yaw, axis: [0, 1, 0])
    }
}
