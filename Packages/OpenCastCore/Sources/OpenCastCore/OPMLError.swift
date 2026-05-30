import Foundation

public enum OPMLError: LocalizedError, Sendable, Equatable {
    case malformedDocument
    case emptySubscriptionList
    case exportFailed

    public var errorDescription: String? {
        switch self {
        case .malformedDocument:
            "This OPML file could not be read. Check that it is valid XML."
        case .emptySubscriptionList:
            "This OPML file does not contain any usable podcast subscriptions."
        case .exportFailed:
            "OpenCast could not create an OPML export file."
        }
    }
}
