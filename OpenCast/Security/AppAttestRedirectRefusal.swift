import Foundation

/// Refuses every redirect of a capped App Attest read, so an envelope only
/// ever reaches the URL it was built for. (The completion-handler form of
/// the delegate method, as the provider client uses.)
nonisolated final class AppAttestRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
