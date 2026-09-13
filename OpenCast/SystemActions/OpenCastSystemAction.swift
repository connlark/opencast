import Foundation

nonisolated enum OpenCastSystemAction: Equatable, Sendable {
    case resume
    case playEpisode(String)
    case playLatest(String)
    case enqueue(String)
    case enqueueNext(String)
    case search(String)
}
