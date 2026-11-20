import SwiftUI

/// Scaled to match the tile's share of the model's frame.
struct SettingsAboutHeroImage: View {
    var body: some View {
        Image(AppIconOption.primary.previewImage)
            .resizable()
            .scaledToFit()
            .scaleEffect(0.75)
            .accessibilityHidden(true)
    }
}
