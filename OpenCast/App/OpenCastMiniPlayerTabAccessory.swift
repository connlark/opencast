import SwiftUI

extension View {
    @ViewBuilder
    func openCastMiniPlayerTabAccessory<Content: View>(
        isEnabled: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: isEnabled) {
                content()
            }
        } else if isEnabled {
            tabViewBottomAccessory {
                content()
            }
        } else {
            self
        }
    }
}
