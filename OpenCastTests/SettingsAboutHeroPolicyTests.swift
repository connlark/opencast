import SwiftUI
import Testing
@testable import OpenCast

@Suite("About hero presentation policy")
struct SettingsAboutHeroPolicyTests {
    @Test("Active, cool and on full power renders the animated model")
    func defaultRendersAnimatedModel() {
        #expect(presentation() == .model(animated: true))
        #expect(presentation(thermalState: .fair) == .model(animated: true))
    }

    @Test("Reduce Motion keeps the model but drops its animation")
    func reduceMotionKeepsStaticModel() {
        #expect(presentation(reduceMotion: true) == .model(animated: false))
    }

    @Test("Low Power Mode, serious or critical heat, and background fall back to the image")
    func costlyStatesFallBackToImage() {
        #expect(presentation(lowPower: true) == .staticImage)
        #expect(presentation(thermalState: .serious) == .staticImage)
        #expect(presentation(thermalState: .critical) == .staticImage)
        #expect(presentation(scenePhase: .background) == .staticImage)
        #expect(presentation(reduceMotion: true, lowPower: true) == .staticImage)
    }

    @Test("Inactive keeps the model so Control Center and app-switcher peeks don't swap art")
    func inactiveKeepsModel() {
        #expect(presentation(scenePhase: .inactive) == .model(animated: true))
    }

    private func presentation(
        reduceMotion: Bool = false,
        lowPower: Bool = false,
        thermalState: ProcessInfo.ThermalState = .nominal,
        scenePhase: ScenePhase = .active
    ) -> SettingsAboutHeroPresentation {
        SettingsAboutHeroPolicy(
            reduceMotion: reduceMotion,
            isLowPowerModeEnabled: lowPower,
            thermalState: thermalState,
            scenePhase: scenePhase
        ).presentation
    }
}
