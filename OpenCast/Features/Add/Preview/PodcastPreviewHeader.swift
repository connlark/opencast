import Foundation
import OpenCastCore

struct PodcastPreviewHeader {
    var title: String?
    var author: String?
    var genre: String?
    var artworkURL: URL?

    init(title: String?, author: String? = nil, genre: String? = nil, artworkURL: URL? = nil) {
        self.title = title
        self.author = author
        self.genre = genre
        self.artworkURL = artworkURL
    }

    init(request: PodcastPreviewRequest, podcast: Podcast?) {
        switch request.subject {
        case .result(let result), .resolvedChoice(let result, _):
            self.init(title: result.title, author: result.artistName, genre: result.genre, artworkURL: result.artworkURL)
        case .feedURL:
            self.init(title: podcast?.title, author: podcast?.author, artworkURL: podcast?.artworkURL)
        }
    }
}
