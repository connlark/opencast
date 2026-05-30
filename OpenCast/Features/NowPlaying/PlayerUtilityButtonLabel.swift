import SwiftUI

struct PlayerUtilityButtonLabel: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.title2)
                .accessibilityHidden(true)

            Text(title)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }
}
