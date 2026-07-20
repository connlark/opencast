import Foundation

/// Pre-create consumption preview: what a job of the given duration would
/// cost against the current balance, mirroring the server's overdraft
/// arithmetic (headroom = available + unused debt cap − reserved).
nonisolated struct RemoteTranscriptionConsumptionEstimate: Sendable, Equatable {
    let estimatedSeconds: Int64
    let availableSeconds: Int64
    let reservedSeconds: Int64
    let debtSeconds: Int64
    /// The portion that would be settled as debt (0 when the balance covers
    /// the whole job).
    let overdraftSeconds: Int64
    /// Whether the server would admit the reservation at all.
    let fitsWithinHeadroom: Bool
}
