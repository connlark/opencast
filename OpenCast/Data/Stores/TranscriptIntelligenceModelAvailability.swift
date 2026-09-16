/// Model-level eligibility as the client reads it from Foundation Models.
/// `PrivateCloudComputeLanguageModel` only distinguishes eligibility from
/// readiness; whether Apple Intelligence is switched on comes from the
/// on-device system model, which PCC requires as well.
nonisolated enum TranscriptIntelligenceModelAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case systemNotReady
}
