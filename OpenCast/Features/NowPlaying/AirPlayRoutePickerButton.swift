import AVFoundation
import SwiftUI

struct AirPlayRoutePickerButton: View {
    @State private var routeName = "Route"
    @State private var isExternalRoute = false

    var body: some View {
        Label(
            "AirPlay",
            systemImage: isExternalRoute ? "airplayaudio.circle.fill" : "airplayaudio"
        )
            .labelStyle(.iconOnly)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .contentTransition(.symbolEffect(.replace))
            .playerUtilityCircleChrome(isActive: isExternalRoute)
            .overlay {
                AirPlayRoutePickerUIView(routeName: routeName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .task {
                await refreshRouteName(disablesAnimations: true)
                for await _ in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                    await refreshRouteName()
                }
            }
    }

    private func refreshRouteName(disablesAnimations: Bool = false) async {
        let route = await Self.currentRoute()
        guard !Task.isCancelled else {
            return
        }

        if disablesAnimations {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                updateRoute(route)
            }
        } else {
            updateRoute(route)
        }
    }

    private func updateRoute(_ route: (name: String, isExternal: Bool)) {
        if routeName != route.name {
            routeName = route.name
        }
        if isExternalRoute != route.isExternal {
            isExternalRoute = route.isExternal
        }
    }

    @concurrent
    private static func currentRoute() async -> (name: String, isExternal: Bool) {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let name = outputs
            .map(\.portName)
            .compactMap(\.trimmedNonEmpty)
            .first ?? "Route"
        let builtInPorts: Set<AVAudioSession.Port> = [.builtInReceiver, .builtInSpeaker]
        return (name, outputs.contains { !builtInPorts.contains($0.portType) })
    }
}
