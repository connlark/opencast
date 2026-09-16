#if DEBUG
import FoundationModels

@Generable(description: "An answer grounded in transcript passages.")
nonisolated struct TranscriptIntelligenceProbeAnswer {
    @Guide(description: "One or two sentences answering the question.")
    var answer: String
    @Guide(description: "Segment ids of the passages the answer relies on.")
    var citations: [Int]
    @Guide(description: "False when the passages do not answer the question.")
    var isAnswerable: Bool
}
#endif
