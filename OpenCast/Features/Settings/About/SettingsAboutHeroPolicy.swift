import SwiftUI

nonisolated struct SettingsAboutHeroPolicy {
    var reduceMotion: Bool
    var isLowPowerModeEnabled: Bool
    var thermalState: ProcessInfo.ThermalState
    var scenePhase: ScenePhase

    var presentation: SettingsAboutHeroPresentation {
        guard !isLowPowerModeEnabled, scenePhase != .background, isThermallyComfortable else {
            return .staticImage
        }
        return .model(animated: !reduceMotion)
    }

    private var isThermallyComfortable: Bool {
        switch thermalState {
        case .nominal, .fair:
            true
        case .serious, .critical:
            false
        @unknown default:
            false
        }
    }
}
