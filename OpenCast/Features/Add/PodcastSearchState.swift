import OpenCastCore

enum PodcastSearchState: Equatable {
    case idle
    case loading
    case empty
    case results([DirectoryPodcastResult])
    case error(String)
}
