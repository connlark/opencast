import SwiftUI

/// Must sit inside the accessory closure: only there does the system report
/// the accessory's placement.
struct TabAccessoryGeometryReader: ViewModifier {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    @State private var frame: CGRect?

    let onChange: (TabAccessoryGeometry) -> Void

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { newFrame in
                frame = newFrame
            }
            .onChange(of: TabAccessoryGeometry(placement: placement, frame: frame), initial: true) { _, geometry in
                onChange(geometry)
            }
    }
}

extension View {
    func reportsTabAccessoryGeometry(_ onChange: @escaping (TabAccessoryGeometry) -> Void) -> some View {
        modifier(TabAccessoryGeometryReader(onChange: onChange))
    }
}
