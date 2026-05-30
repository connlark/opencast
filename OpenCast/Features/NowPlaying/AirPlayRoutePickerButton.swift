import AVFoundation
import AVKit
import SwiftUI

struct AirPlayRoutePickerButton: View {
    @State private var routeName = Self.currentRouteName()

    var body: some View {
        ZStack {
            PlayerUtilityButtonLabel(title: "AirPlay", value: routeName, systemImage: "airplayaudio")
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            AirPlayRoutePickerUIView()
                // A fully transparent AVRoutePickerView stops receiving taps.
                .opacity(0.02)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("AirPlay")
                .accessibilityHint("Choose an audio route")
        }
        .playerUtilityButtonChrome()
        .accessibilityValue(routeName)
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
