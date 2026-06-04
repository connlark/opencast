import Foundation
import SwiftUI

struct OnboardingPitchRow: View {
    let systemImage: String
    let title: String
    let message: String
    let destination: URL?

    init(
        systemImage: String,
        title: String,
        message: String,
        destination: URL? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.destination = destination
    }

    var body: some View {
        if let destination {
            Link(destination: destination) {
                rowContent
            }
            .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(.red)
                .frame(width: 28, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if destination != nil {
                Image(systemName: "arrow.up.forward")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
