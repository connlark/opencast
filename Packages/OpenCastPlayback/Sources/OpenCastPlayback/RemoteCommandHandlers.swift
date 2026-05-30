import Foundation

struct RemoteCommandHandlers: Sendable {
    let play: @MainActor () -> Void
    let pause: @MainActor () -> Void
    let togglePlayPause: @MainActor () -> Void
    let skipForward: @MainActor () -> Void
    let skipBackward: @MainActor () -> Void
    let seek: @MainActor (TimeInterval) -> Void
}
