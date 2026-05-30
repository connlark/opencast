import Foundation

nonisolated struct RemoteCommandState: Equatable, Sendable {
    var hasLoadedContent: Bool
    var isSeekable: Bool
    var duration: TimeInterval?

    static let empty = RemoteCommandState(
        hasLoadedContent: false,
        isSeekable: false,
        duration: nil
    )
}
