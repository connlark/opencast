/// What a tier check found. Closed, and carrying nothing Google said.
public enum AnalysisTierCheckResult: Sendable, Hashable {
    /// Google refused the key, naming the free tier.
    case freeTier
    /// Google answered: the key can use a model the free tier cannot.
    case notFreeTier
    /// Anything else. A missing model, an outage or a timeout says nothing
    /// about the tier, so this never reroutes and never changes a state.
    case inconclusive
}
