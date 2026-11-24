import Foundation
import OpenCastCore

enum PodcastPreviewFailure {
    case offline
    case noResponse(host: String)
    case errorResponse(host: String)
    case notAPodcastFeed(host: String)
    case tooLarge(message: String)
    case noFeed

    init?(error: any Error, host: String) {
        guard !Self.isCancellation(error) else {
            return nil
        }
        if FeedTransportErrorClassifier.isUnreachable(error) {
            self = .offline
            return
        }
        switch error as? OpenCastCoreError {
        case .unexpectedStatusCode, .invalidHTTPResponse:
            self = .errorResponse(host: host)
        case .incompleteFeed(.interruptedTransfer):
            self = .noResponse(host: host)
        case .feedTooLarge:
            self = .tooLarge(message: error.localizedDescription)
        case .some:
            self = .notAPodcastFeed(host: host)
        case nil:
            self = error is URLError ? .noResponse(host: host) : .notAPodcastFeed(host: host)
        }
    }

    var title: String {
        switch self {
        case .offline: "You’re Offline"
        case .noResponse, .errorResponse: "Couldn’t Reach the Feed"
        case .notAPodcastFeed, .tooLarge: "Couldn’t Read the Feed"
        case .noFeed: "No RSS Feed"
        }
    }

    var message: String {
        switch self {
        case .offline: "Connect to the internet and try again."
        case .noResponse(let host): "\(host) didn’t respond."
        case .errorResponse(let host): "\(host) returned an error."
        case .notAPodcastFeed(let host): "\(host) didn’t send a podcast feed."
        case .tooLarge(let message): message
        case .noFeed: "The directory did not provide an RSS feed for this podcast."
        }
    }

    var systemImage: String {
        switch self {
        case .offline: "wifi.slash"
        case .noResponse, .errorResponse: "antenna.radiowaves.left.and.right.slash"
        case .notAPodcastFeed, .tooLarge: "doc.questionmark"
        case .noFeed: "exclamationmark.circle"
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
