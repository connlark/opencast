import SwiftUI

struct PlayerUtilityButton: View {
    let title: String
    let value: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PlayerUtilityButtonLabel(title: title, value: value, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .playerUtilityButtonChrome()
    }
}
