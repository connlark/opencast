import Foundation
import OpenCastCore

enum OpenCastSamplePodcastSuggestions {
    static let all = [
        DirectoryPodcastResult(
            id: 201_671_138,
            title: "This American Life",
            artistName: "This American Life",
            feedURL: URL(string: OpenCastConstants.thisAmericanLifeFeedURL),
            artworkURL: URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Podcasts221/v4/64/aa/3a/64aa3a66-a08a-947c-cf21-a5722a1b77ae/mza_11390421932467026234.png/600x600bb.jpg"),
            collectionViewURL: URL(string: "https://www.thisamericanlife.org")
        ),
        DirectoryPodcastResult(
            id: 1_853_007_888,
            title: "The Rest Is Science",
            artistName: "Goalhanger",
            feedURL: URL(string: OpenCastConstants.restIsScienceFeedURL),
            artworkURL: URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Podcasts211/v4/10/e6/4d/10e64d1a-6747-2500-6add-ca04616d5686/mza_1900430593839428227.jpg/600x600bb.jpg"),
            collectionViewURL: URL(string: "https://podcasts.apple.com/us/podcast/the-rest-is-science/id1853007888?uo=4")
        )
    ]
}
