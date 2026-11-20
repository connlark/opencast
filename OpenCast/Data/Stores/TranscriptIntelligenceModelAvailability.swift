/// `PrivateCloudComputeLanguageModel` reports only eligibility and readiness; whether Apple
/// Intelligence is on comes from the on-device system model, which PCC also requires.
nonisolated enum TranscriptIntelligenceModelAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case systemNotReady
}
