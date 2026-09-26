/// Which party owns the completion notification for a remote job. Snapshotted
/// onto run/queue outcomes before the runner clears its reference, so delivery
/// never reads a reference after cleanup. References persisted before this
/// field existed decode as `local`.
nonisolated enum JobCompletionDeliveryOwner: String, Codable, Sendable {
    case local
    case remote
}
