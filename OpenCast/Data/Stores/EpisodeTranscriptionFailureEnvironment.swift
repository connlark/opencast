import UIKit

struct EpisodeTranscriptionFailureEnvironment: Equatable {
    enum SceneState: String {
        case active
        case inactive
        case background
        case unknown
    }

    var sceneState: SceneState
    var isProtectedDataAvailable: Bool

    var isConstrained: Bool {
        sceneState != .active || !isProtectedDataAvailable
    }

    static let foreground = EpisodeTranscriptionFailureEnvironment(
        sceneState: .active,
        isProtectedDataAvailable: true
    )

    static func current() -> EpisodeTranscriptionFailureEnvironment {
        EpisodeTranscriptionFailureEnvironment(
            sceneState: UIApplication.shared.applicationState.transcriptionFailureSceneState,
            isProtectedDataAvailable: UIApplication.shared.isProtectedDataAvailable
        )
    }
}

private extension UIApplication.State {
    var transcriptionFailureSceneState: EpisodeTranscriptionFailureEnvironment.SceneState {
        switch self {
        case .active:
            .active
        case .inactive:
            .inactive
        case .background:
            .background
        @unknown default:
            .unknown
        }
    }
}
