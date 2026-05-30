import Foundation

struct ITunesPopularPodcastChartResult: Decodable, Sendable {
    var id: Int
    var name: String
    var artistName: String?
    var artworkUrl100: URL?
    var url: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case artistName
        case artworkUrl100
        case url
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringID = try? container.decode(String.self, forKey: .id),
           let intID = Int(stringID) {
            id = intID
        } else {
            id = try container.decode(Int.self, forKey: .id)
        }
        name = try container.decode(String.self, forKey: .name)
        artistName = try container.decodeIfPresent(String.self, forKey: .artistName)
        artworkUrl100 = try container.decodeIfPresent(URL.self, forKey: .artworkUrl100)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
    }
}
