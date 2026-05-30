import Foundation

nonisolated struct CacheFileCandidate: Sendable {
    var url: URL
    var byteCount: Int64
    var lastAccess: Date
    var isCompleted: Bool = false
}
