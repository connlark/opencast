import Foundation

/// Decoded input and processing ceilings shared with NotificationsWorker.
/// scripts/check-feed-resource-policy.py guards the cross-language contract.
public enum FeedResourcePolicy {
    public static let maximumDecodedBytes = 128 * 1_024 * 1_024
    public static let maximumItems = 100_000
    public static let maximumDepth = 50
    public static let maximumFieldBytes = 12 * 1_024 * 1_024
    public static let maximumItemTextBytes = 16 * 1_024 * 1_024
    public static let maximumProcessingBytes = 512 * 1_024 * 1_024
    public static let chunkBytes = 64 * 1_024
    public static let importBatchRows = 256
    public static let importBatchTextBytes = 1_024 * 1_024
    public static let processingVersion = 2
}

public enum FeedIncompleteReason: Codable, Hashable, Sendable {
    case decodedByteLimit
    case itemLimit
    case depthLimit
    case fieldLimit
    case itemTextLimit
    case processingLimit
    case interruptedTransfer(String)
    case malformedXML(String)

    public var diagnostic: String {
        switch self {
        case .decodedByteLimit: "The feed exceeded 128 MiB of decoded XML."
        case .itemLimit: "The feed exceeded 100,000 RSS items."
        case .depthLimit: "The feed exceeded 50 levels of XML nesting."
        case .fieldLimit: "A feed field exceeded 12 MiB of text."
        case .itemTextLimit: "An episode exceeded 16 MiB of text."
        case .processingLimit: "The feed exceeded its text processing budget."
        case let .interruptedTransfer(reason): "The feed transfer was interrupted: \(reason)"
        case let .malformedXML(reason): "Part of the feed could not be parsed: \(reason)"
        }
    }
}

public enum FeedCompleteness: Codable, Hashable, Sendable {
    case complete
    case partial(FeedIncompleteReason)

    public var isComplete: Bool { self == .complete }
    public var reason: FeedIncompleteReason? {
        if case let .partial(reason) = self { return reason }
        return nil
    }
    public static let partialNotice = "Some episodes couldn’t be loaded. Available episodes are ready to play."
}
