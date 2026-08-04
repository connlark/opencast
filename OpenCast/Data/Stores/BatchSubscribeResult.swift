import Foundation

nonisolated struct BatchSubscribeResult: Equatable, Sendable {
    var subscribedFeedURLStrings: [String] = []
    var failures: [BatchSubscribeFailure] = []
}

nonisolated struct BatchSubscribeFailure: Equatable, Sendable {
    let feedURLString: String
    let message: String
}
