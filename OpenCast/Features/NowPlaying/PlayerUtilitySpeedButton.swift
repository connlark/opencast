import SwiftUI

struct PlayerUtilitySpeedButton: View {
    let rate: Float
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(rate.formattedSpeed)
                .font(.body)
                .bold()
                .minimumScaleFactor(0.7)
        }
        .buttonStyle(.plain)
        .playerUtilityCircleChrome()
        .accessibilityLabel("Playback Speed")
        .accessibilityValue(rate.formattedSpeed)
        .accessibilityInputLabels(["Speed", "Playback Speed"])
    }
}
