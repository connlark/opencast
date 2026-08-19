import SwiftUI

struct PodcastPlaybackSkipRow: View {
    let title: String
    let fieldAccessibilityIdentifier: String
    @Binding var text: String
    let onDecrease: () -> Void
    let onIncrease: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(title) {
                TextField("0:00", text: $text)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("\(title) duration")
                    .accessibilityIdentifier(fieldAccessibilityIdentifier)
            }

            Stepper(onIncrement: onIncrease, onDecrement: onDecrease) {
                Text("Adjust in 5-second steps")
            }
            .accessibilityLabel("Adjust \(title)")
            .accessibilityValue(text)
            .accessibilityIdentifier("Adjust \(title)")
        }
    }
}
