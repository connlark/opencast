import OpenCastTranscription

/// User-facing interpretation of the Worker's optional ETA metadata.
nonisolated enum RemoteTranscriptionEstimate: Equatable {
    case onTrack(remainingSeconds: Int)
    case queued(remainingSeconds: Int?)
    case delayed

    init?(progress: OpenCastRemoteTranscriptionJobProgress?) {
        guard let status = progress?.estimateStatus else {
            return nil
        }
        switch status {
        case .onTrack:
            guard let seconds = progress?.estimatedRemainingSeconds, seconds > 0 else {
                return nil
            }
            self = .onTrack(remainingSeconds: seconds)
        case .queued:
            self = .queued(remainingSeconds: progress?.estimatedRemainingSeconds)
        case .delayed:
            self = .delayed
        case .unknown:
            return nil
        }
    }

    var displayText: String {
        switch self {
        case let .onTrack(seconds):
            return Self.bucketText(for: seconds) + "."
        case let .queued(seconds):
            guard let seconds, seconds > 0 else {
                return "Waiting for an open slot."
            }
            return "Waiting for an open slot — \(Self.bucketText(for: seconds).lowercased())."
        case .delayed:
            return "Taking longer than usual — still working"
        }
    }

    private static func bucketText(for seconds: Int) -> String {
        switch seconds {
        case ...14:
            return "Finishing up"
        case 15...44:
            return "About \(max(10, ((seconds + 5) / 10) * 10)) seconds remaining"
        case 45...89:
            return "About 1 minute remaining"
        default:
            let minutes = max(2, (seconds + 30) / 60)
            return "About \(minutes) minutes remaining"
        }
    }
}
