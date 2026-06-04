import SwiftUI

struct ArtworkPlaceholderVisual: View {
    let title: String
    let image: UIImage?
    let preview: ArtworkPreview?

    @ViewBuilder
    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else if let preview {
            ArtworkPreviewImage(preview: preview)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(placeholderBackground)
                .overlay {
                    placeholderText
                }
        }
    }

    private var placeholderText: some View {
        Text(title.initials)
            .font(.headline)
            .foregroundStyle(.white)
            .minimumScaleFactor(0.6)
            .padding(6)
    }

    private var placeholderBackground: some ShapeStyle {
        .linearGradient(
            colors: [.teal, .indigo],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
