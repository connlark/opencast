import Foundation
import Testing
@testable import OpenCast

@Suite("About hero drag-to-turn math")
struct SettingsAboutHeroYawGestureTests {
    @Test("The dominant component of the movement picks the axis")
    func axisFollowsDominantComponent() {
        #expect(SettingsAboutHeroYawGesture.axis(for: CGSize(width: 13, height: 4)) == .horizontal)
        #expect(SettingsAboutHeroYawGesture.axis(for: CGSize(width: -13, height: 4)) == .horizontal)
        #expect(SettingsAboutHeroYawGesture.axis(for: CGSize(width: 4, height: -13)) == .vertical)
        #expect(SettingsAboutHeroYawGesture.axis(for: CGSize(width: 9, height: 9)) == .vertical)
    }

    @Test("One point turns 0.6 degrees, clamped to 120 degrees either way")
    func offsetScalesAndClamps() {
        #expect(abs(offset(100) - radians(60)) < 1e-9)
        #expect(abs(offset(-50) - radians(-30)) < 1e-9)
        #expect(abs(offset(1_000) - radians(120)) < 1e-9)
        #expect(abs(offset(-1_000) - radians(-120)) < 1e-9)
    }

    @Test("A release projects the drag's velocity 0.2 seconds ahead")
    func releaseProjectsVelocity() {
        #expect(SettingsAboutHeroYawGesture.releaseTranslation(translation: 40, velocity: 1_000) == 240)
        #expect(SettingsAboutHeroYawGesture.releaseTranslation(translation: 40, velocity: 0) == 40)
        #expect(SettingsAboutHeroYawGesture.releaseTranslation(translation: -40, velocity: -500) == -140)
    }

    @Test("Releasing past a quarter turn settles on the other face")
    func releaseSnapsToNearestFace() {
        #expect(SettingsAboutHeroYawGesture.showsBack(afterReleasingAt: radians(80), showingBack: false) == false)
        #expect(SettingsAboutHeroYawGesture.showsBack(afterReleasingAt: radians(100), showingBack: false) == true)
        #expect(SettingsAboutHeroYawGesture.showsBack(afterReleasingAt: radians(-100), showingBack: false) == true)
        #expect(SettingsAboutHeroYawGesture.showsBack(afterReleasingAt: radians(-100), showingBack: true) == false)
        #expect(SettingsAboutHeroYawGesture.showsBack(afterReleasingAt: radians(30), showingBack: true) == true)
    }

    private func offset(_ width: Double) -> Double {
        SettingsAboutHeroYawGesture.offset(forHorizontalTranslation: width)
    }

    private func radians(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }
}
