import Foundation

enum EpisodeMetadataChip: Equatable, Identifiable {
    case publishDate(Date)
    case duration(String)
    case remaining(String, fractionCompleted: Double)
    case downloaded(fileSize: String?)
    case played
    case playlists(count: Int)

    var id: String {
        switch self {
        case .publishDate:
            "publishDate"
        case .duration:
            "duration"
        case .remaining:
            "remaining"
        case .downloaded:
            "downloaded"
        case .played:
            "played"
        case .playlists:
            "playlists"
        }
    }
}
