import AVFoundation
import SwiftUI

struct AirPlayRoutePickerButton: View {
    @State private var routeName = Self.currentRouteName()

    var body: some View {
        PlayerUtilityButtonLabel(title: "AirPlay", value: routeName, systemImage: "airplayaudio")
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .playerUtilityButtonChrome()
            .overlay {
                AirPlayRoutePickerUIView(routeName: routeName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .task {
                refreshRouteName()
                for await _ in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                    refreshRouteName()
                }
            }
    }

    private func refreshRouteName() {
        routeName = Self.currentRouteName()
    }

    private static func currentRouteName() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs
            .map(\.portName)
            .compactMap(\.trimmedNonEmpty)
            .first ?? "Route"
    }
}
