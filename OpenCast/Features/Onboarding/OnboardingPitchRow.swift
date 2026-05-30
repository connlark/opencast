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
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.red)
        }
        .labelStyle(.titleAndIcon)
    }
}
