import Foundation

#if DEBUG
import BackgroundTasks
import UIKit
#endif

enum AdFreePassBackgroundEnvironmentSnapshot {
    static func record(reason: String) {
        #if DEBUG
        UIDevice.current.isBatteryMonitoringEnabled = true
        AdFreePassBackgroundRunLog.record("environment reason=\(reason) \(description)")
        #endif
    }

    #if DEBUG
    private static var description: String {
        let device = UIDevice.current
        let processInfo = ProcessInfo.processInfo
        return [
            "applicationState=\(UIApplication.shared.applicationState.backgroundLogDescription)",
            "backgroundRefresh=\(UIApplication.shared.backgroundRefreshStatus.backgroundLogDescription)",
            "lowPowerMode=\(processInfo.isLowPowerModeEnabled)",
            "thermal=\(processInfo.thermalState.backgroundLogDescription)",
            "protectedDataAvailable=\(UIApplication.shared.isProtectedDataAvailable)",
            "batteryState=\(device.batteryState.backgroundLogDescription)",
            "batteryLevel=\(batteryLevelDescription(device.batteryLevel))",
            "supportedResources=\(BGTaskScheduler.supportedResources.rawValue)"
        ].joined(separator: " ")
    }

    private static func batteryLevelDescription(_ batteryLevel: Float) -> String {
        guard batteryLevel >= 0 else {
            return "unknown"
        }
        return batteryLevel.backgroundLogNumber
    }
    #endif
}

#if DEBUG
private extension UIApplication.State {
    var backgroundLogDescription: String {
        switch self {
        case .active:
            "active"
        case .inactive:
            "inactive"
        case .background:
            "background"
        @unknown default:
            "unknown"
        }
    }
}

private extension UIBackgroundRefreshStatus {
    var backgroundLogDescription: String {
        switch self {
        case .available:
            "available"
        case .denied:
            "denied"
        case .restricted:
            "restricted"
        @unknown default:
            "unknown"
        }
    }
}

private extension UIDevice.BatteryState {
    var backgroundLogDescription: String {
        switch self {
        case .unknown:
            "unknown"
        case .unplugged:
            "unplugged"
        case .charging:
            "charging"
        case .full:
            "full"
        @unknown default:
            "unknown"
        }
    }
}

private extension ProcessInfo.ThermalState {
    var backgroundLogDescription: String {
        switch self {
        case .nominal:
            "nominal"
        case .fair:
            "fair"
        case .serious:
            "serious"
        case .critical:
            "critical"
        @unknown default:
            "unknown"
        }
    }
}
#endif
