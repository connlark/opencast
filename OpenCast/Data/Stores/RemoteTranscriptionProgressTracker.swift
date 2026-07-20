import OpenCastTranscription

/// Converts wire status into one atomic processing snapshot and retains the
/// largest determinate fraction each job has displayed.
final class RemoteTranscriptionProgressTracker {
    private var maximumFractionsByJobID: [String: Double] = [:]

    func activeProgress(
        for job: OpenCastRemoteTranscriptionJobStatus
    ) -> RemoteTranscriptionActiveProgress? {
        let stage: RemoteTranscriptionActiveStage
        switch job.state {
        case .sourceMatched, .probing, .reserved:
            stage = .checkingAudioDetails
        case .chunking, .transcribing:
            stage = .transcribing
        case .stitching:
            stage = .finalizing
        default:
            return nil
        }

        let completed = job.progress?.chunksCompleted
        let total = job.progress?.chunksTotal
        let candidate = Self.fraction(completed: completed, total: total)
        let prior = maximumFractionsByJobID[job.jobID]
        let retained: Double? = switch (prior, candidate) {
        case let (prior?, candidate?): max(prior, candidate)
        case let (prior?, nil): prior
        case let (nil, candidate?): candidate
        case (nil, nil): nil
        }
        if let retained {
            maximumFractionsByJobID[job.jobID] = retained
        }

        return RemoteTranscriptionActiveProgress(
            stage: stage,
            completedChunks: completed,
            totalChunks: total,
            fractionCompleted: retained,
            estimate: RemoteTranscriptionEstimate(progress: job.progress)
        )
    }

    func remove(jobID: String) {
        maximumFractionsByJobID[jobID] = nil
    }

    private static func fraction(completed: Int?, total: Int?) -> Double? {
        guard let completed, let total, total > 0 else {
            return nil
        }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}
