import FoundationModels

@Generable
nonisolated struct TranscriptPassagesToolArguments: Equatable, Sendable {
    @Guide(description: "Two to six distinctive words from the question to look for in the transcript.")
    var query: String
}
