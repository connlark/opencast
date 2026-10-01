/// One episode's retrieval text: the lexical document and the text the
/// word-vector lane embeds.
nonisolated struct EpisodeMetadataLine: Equatable, Sendable {
    /// The episode index.
    var position: Int
    /// UTC publication date, title and the kept snippet.
    var lexicalText: String
    /// The title without the show-wide prefix, plus the kept snippet when there is one.
    var semanticText: String
}
