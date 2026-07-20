import Foundation

/// Bridges `handleEventsForBackgroundURLSession` completion handlers from the
/// app delegate to the upload transport whose session identifier matches.
/// iOS relaunches the app for background upload events; the handler must be
/// called once the session's queued events have been delivered.
final class RemoteTranscriptionUploadBackgroundEvents {
    static let shared = RemoteTranscriptionUploadBackgroundEvents()

    private var handlers: [String: () -> Void] = [:]

    func store(_ completionHandler: @escaping () -> Void, for identifier: String) {
        handlers[identifier] = completionHandler
    }

    func finishEvents(for identifier: String) {
        handlers.removeValue(forKey: identifier)?()
    }
}
