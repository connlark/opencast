import Foundation

/// Mirrors the server's overdraft arithmetic: headroom = available + unused debt cap − reserved.
nonisolated struct RemoteTranscriptionConsumptionEstimate: Sendable, Equatable {
    let estimatedSeconds: Int64
    let availableSeconds: Int64
    let reservedSeconds: Int64
    let debtSeconds: Int64
    /// The portion settled as debt; 0 when the balance covers the whole job.
    let overdraftSeconds: Int64
    let fitsWithinHeadroom: Bool
}
