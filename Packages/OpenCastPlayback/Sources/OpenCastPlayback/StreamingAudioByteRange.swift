import Foundation

nonisolated struct StreamingAudioByteRange: Codable, Equatable, Sendable {
    var lowerBound: Int64
    var upperBound: Int64

    init(lowerBound: Int64, upperBound: Int64) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    init(_ range: Range<Int64>) {
        self.init(lowerBound: range.lowerBound, upperBound: range.upperBound)
    }

    var range: Range<Int64> {
        lowerBound..<upperBound
    }

    var byteCount: Int64 {
        max(upperBound - lowerBound, 0)
    }

    func contains(_ range: Range<Int64>) -> Bool {
        lowerBound <= range.lowerBound && upperBound >= range.upperBound
    }

    func overlapsOrTouches(_ other: StreamingAudioByteRange) -> Bool {
        lowerBound <= other.upperBound && other.lowerBound <= upperBound
    }

    func merged(with other: StreamingAudioByteRange) -> StreamingAudioByteRange {
        StreamingAudioByteRange(
            lowerBound: min(lowerBound, other.lowerBound),
            upperBound: max(upperBound, other.upperBound)
        )
    }
}
