import FoundationModels

@Generable(description: "A recap of one podcast transcript window for a listener who is resuming the episode.")
nonisolated struct TranscriptRecap: Equatable, Sendable {
    @Guide(description: "Three to six short bullets, in the order things happened in the window.", .count(3...6))
    var bullets: [TranscriptRecapBullet]
}
