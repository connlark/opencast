import AVFoundation
import SwiftUI

struct AirPlayRoutePickerButton: View {
    @State private var routeName = "Route"

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
                await refreshRouteName()
                for await _ in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                    await refreshRouteName()
                }
            }
    }

    private func refreshRouteName() async {
        let currentRouteName = await Self.currentRouteName()
        guard !Task.isCancelled, routeName != currentRouteName else {
            return
        }

        routeName = currentRouteName
    }

    @concurrent
    private static func currentRouteName() async -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs
            .map(\.portName)
            .compactMap(\.trimmedNonEmpty)
            .first ?? "Route"
    }
}
