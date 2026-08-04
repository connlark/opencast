import SwiftUI

@main
struct OpenCastApp: App {
    @UIApplicationDelegateAdaptor(OpenCastAppDelegate.self) private var appDelegate

    private let runtime = OpenCastAppRuntime.shared

    var body: some Scene {
        WindowGroup {
            OpenCastRootView()
                .environment(runtime.appModel)
                .environment(
                    \.isAppStoreScreenshotCapture,
                    runtime.launchConfiguration.seedsAppStoreScreenshotData
                )
                .modelContainer(runtime.modelContainer)
                .preferredColorScheme(preferredColorScheme)
        }
        .commands {
            OpenCastCommands()
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch runtime.launchConfiguration.forcedAppearance {
        case .system:
            userPreferredColorScheme
        case .dark:
            .dark
        case .light:
            .light
        }
    }

    private var userPreferredColorScheme: ColorScheme? {
        switch runtime.appModel.appearanceSettings.mode {
        case .system:
            nil
        case .dark:
            .dark
        case .light:
            .light
        }
    }
}
