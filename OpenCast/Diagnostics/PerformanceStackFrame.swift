import Foundation

nonisolated struct PerformanceStackFrame: Codable, Equatable, Sendable {
    let binaryUUID: UUID?
    let address: UInt64?
    let offset: UInt64?
    let samples: Int?
    let depth: Int
    let thread: Int
}
