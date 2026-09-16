import FoundationModels

@Generable
nonisolated struct TranscriptRangeToolArguments: Equatable, Sendable {
    @Guide(description: "The moment in the episode to read around, in seconds from the start.")
    var seconds: Int
    @Guide(description: "How many seconds of transcript to return, centered on that moment.", .range(30...300))
    var spanSeconds: Int
}
