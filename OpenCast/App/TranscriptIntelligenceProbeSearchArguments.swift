#if DEBUG
import FoundationModels

@Generable
nonisolated struct TranscriptIntelligenceProbeSearchArguments {
    @Guide(description: "Words to look for in the transcript.")
    var query: String
}
#endif
