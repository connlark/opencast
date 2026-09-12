import Foundation

public struct OpenCastAdBoundaryResolution: Codable, Sendable, Equatable {
    public var time: TimeInterval
    public var wordIndex: Int?
    public var fallbackReason: String?

    public var isRefined: Bool { wordIndex != nil && fallbackReason == nil }

    public init(time: TimeInterval, wordIndex: Int? = nil, fallbackReason: String? = nil) {
        self.time = time
        self.wordIndex = wordIndex
        self.fallbackReason = fallbackReason
    }
}
