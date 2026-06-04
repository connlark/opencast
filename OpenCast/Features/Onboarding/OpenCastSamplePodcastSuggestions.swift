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
            id: 203_970_211,
            title: "LibriVox Community Podcast",
            artistName: "LibriVox",
            feedURL: URL(string: OpenCastConstants.libriVoxCommunityFeedURL),
            artworkURL: URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Podcasts2/v4/64/bd/65/64bd652c-180e-8687-77d6-bacec4854cf4/mza_7042823672686999515.jpg/600x600bb.jpg"),
            collectionViewURL: URL(string: "https://wiki.librivox.org/index.php/Librivox_Community_Podcast")
        )
    ]
}
