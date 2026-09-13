import Foundation

nonisolated struct OpenCastSearchRequest: Equatable, Sendable {
    let id = UUID()
    let query: String
}
