import SwiftUI

struct PlayerUtilityCircleButton: View {
    let title: String
    let systemImage: String
    var isActive = false
    var replacesSymbol = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .contentTransition(
                        replacesSymbol ? .symbolEffect(.replace) : .identity
                    )
            }
            .labelStyle(.iconOnly)
        }
            .buttonStyle(.plain)
            .playerUtilityCircleChrome(isActive: isActive)
    }
}
