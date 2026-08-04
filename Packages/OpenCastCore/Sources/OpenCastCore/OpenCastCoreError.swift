import Foundation

public enum OpenCastCoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidFeedURL
    case invalidHTTPResponse
    case unexpectedStatusCode(Int)
    case notAFeed(rootElement: String?)
    case malformedFeed(reason: String?)
    case feedTooLarge(byteLimit: Int)
    case missingAudioURL

    public var errorDescription: String? {
        switch self {
        case .invalidFeedURL:
            "Enter a valid RSS feed URL."
        case .invalidHTTPResponse:
            "The server did not return a valid response."
        case .unexpectedStatusCode(let statusCode):
            "The server returned HTTP \(statusCode)."
        case .notAFeed(let rootElement):
            switch rootElement {
            case "feed":
                "This is an Atom feed. OpenCast supports RSS feeds only."
            case "html":
                "This address returned a web page instead of an RSS feed."
            default:
                "This address did not return an RSS podcast feed."
            }
        case .malformedFeed:
            "This feed could not be read because its XML is invalid."
        case .feedTooLarge(let byteLimit):
            "This feed is larger than \(byteLimit / (1_024 * 1_024)) MB and can't be loaded."
        case .missingAudioURL:
            "This episode does not include an audio file."
        }
    }
}
