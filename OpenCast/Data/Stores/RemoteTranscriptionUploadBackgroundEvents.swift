import Foundation

/// A `handleEventsForBackgroundURLSession` handler must run only once its session's queued
/// events have been delivered.
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
