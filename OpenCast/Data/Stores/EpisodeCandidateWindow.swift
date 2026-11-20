nonisolated struct EpisodeCandidateWindow: Equatable, Sendable {
    /// The lexical block in its ranked order, then the word-vector fill in similarity order.
    var rankedPositions: [Int]
    /// The same set, ascending: the order the lines are sent in.
    var positions: [Int]
    var lexicalCount: Int
    var fillCount: Int
}
