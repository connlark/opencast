import Foundation

public enum OpenCastCoreError: Error, LocalizedError, Sendable {
    case invalidFeedURL
    case invalidHTTPResponse
    case unexpectedStatusCode(Int)
    case emptyFeed
    case missingAudioURL

    public var errorDescription: String? {
        switch self {
        case .invalidFeedURL:
            "Enter a valid RSS feed URL."
        case .invalidHTTPResponse:
            "The server did not return a valid response."
        case .unexpectedStatusCode(let statusCode):
            "The server returned HTTP \(statusCode)."
        case .emptyFeed:
            "This feed did not contain any podcast episodes."
        case .missingAudioURL:
            "This episode does not include an audio file."
        }
    }
}
