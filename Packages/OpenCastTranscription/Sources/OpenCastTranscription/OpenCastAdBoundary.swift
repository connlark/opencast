import Foundation

/// A source-verified phrase, resolved only against words in this exact segment.
public struct OpenCastAdBoundary: Codable, Sendable, Equatable {
    public var segmentID: Int
    public var quote: String

    public init(segmentID: Int, quote: String) {
        self.segmentID = segmentID
        self.quote = quote
    }

    enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case quote
    }

    public init(from decoder: any Decoder) throws {
        // A malformed optional refinement must not discard a valid coarse ad.
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        segmentID = (try? container?.decode(Int.self, forKey: .segmentID)) ?? -1
        quote = (try? container?.decode(String.self, forKey: .quote)) ?? ""
    }
}
