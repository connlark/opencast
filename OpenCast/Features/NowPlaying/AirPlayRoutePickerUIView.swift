import AVKit
import SwiftUI

struct AirPlayRoutePickerUIView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .clear
        view.activeTintColor = .clear
        view.backgroundColor = .clear
        view.accessibilityLabel = "AirPlay"
        view.accessibilityHint = "Choose an audio route"
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = .clear
        view.activeTintColor = .clear
        view.accessibilityLabel = "AirPlay"
        view.accessibilityHint = "Choose an audio route"
    }
}
