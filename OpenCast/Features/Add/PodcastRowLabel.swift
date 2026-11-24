import SwiftUI

struct PodcastRowLabel<Mark: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let author: String?
    let artworkURL: String?
    let mark: Mark

    init(title: String, author: String?, artworkURL: String?, @ViewBuilder mark: () -> Mark) {
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.mark = mark()
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkPlaceholder(title: title, imageURL: artworkURL, size: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)

                if let author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }

                mark
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension PodcastRowLabel where Mark == EmptyView {
    init(title: String, author: String?, artworkURL: String?) {
        self.init(title: title, author: author, artworkURL: artworkURL) {
            EmptyView()
        }
    }
}
