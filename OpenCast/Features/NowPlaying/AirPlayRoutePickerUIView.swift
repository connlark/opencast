import SwiftUI

struct AirPlayRoutePickerUIView: UIViewRepresentable {
    var routeName: String

    func makeUIView(context: Context) -> AccessibleAirPlayRoutePickerView {
        let view = AccessibleAirPlayRoutePickerView()
        view.update(routeName: routeName)
        return view
    }

    func updateUIView(_ view: AccessibleAirPlayRoutePickerView, context: Context) {
        view.update(routeName: routeName)
    }
}
