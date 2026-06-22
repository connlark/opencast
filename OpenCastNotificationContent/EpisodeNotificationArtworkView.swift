import SwiftUI

struct EpisodeNotificationArtworkView: View {
    let image: UIImage?
    let initials: String
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle()
                        .fill(.quaternary)
                    Text(initials)
                        .font(.title2.bold())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}
