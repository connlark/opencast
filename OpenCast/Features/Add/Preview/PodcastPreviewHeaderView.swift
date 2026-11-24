import SwiftUI

struct PodcastPreviewHeaderView: View {
    let header: PodcastPreviewHeader
    let showsFacts: Bool
    let isInLibrary: Bool
    let onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if showsFacts {
                ArtworkPlaceholder(
                    title: header.title ?? "",
                    imageURL: header.artworkURL?.absoluteString,
                    size: 88
                )
                .clipShape(.rect(cornerRadius: 10))

                VStack(alignment: .leading, spacing: isInLibrary ? 2 : 3) {
                    Text(header.title ?? "Podcast Title")
                        .font(.title3)
                        .bold()
                        .lineLimit(2)
                        .redacted(reason: header.title == nil ? .placeholder : [])
                    if let author = header.author, !author.isEmpty {
                        Text(author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let genre = header.genre, !genre.isEmpty {
                        Text(genre)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if isInLibrary {
                        PodcastInLibraryLabel()
                            .font(.subheadline)
                    }
                }
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }

            if let onClose {
                Button("Close", systemImage: "xmark", role: .close, action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .accessibilityIdentifier("Podcast Preview Close")
            }
        }
    }
}
