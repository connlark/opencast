import OpenCastCore

enum PopularPodcastsState: Equatable {
    case idle
    case loading
    case loaded([DirectoryPodcastResult])
    case empty
    case failed(String)
}
