import Foundation

public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case buffering
    case paused
    case playing
    case failed(String)

    public nonisolated var showsPauseButton: Bool {
        switch self {
        case .playing, .buffering, .loading:
            true
        case .idle, .paused, .failed:
            false
        }
    }

    public nonisolated var showsLoadingIndicator: Bool {
        switch self {
        case .buffering, .loading:
            true
        case .idle, .paused, .playing, .failed:
            false
        }
    }

    public nonisolated var accessibilityDescription: String {
        switch self {
        case .idle:
            "Idle"
        case .loading:
            "Loading"
        case .buffering:
            "Buffering"
        case .paused:
            "Paused"
        case .playing:
            "Playing"
        case .failed:
            "Playback Failed"
        }
    }
}
