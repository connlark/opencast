import FoundationModels

@Generable(description: "One recap bullet and the transcript segment that supports it.")
nonisolated struct TranscriptRecapBullet: Equatable, Sendable {
    @Guide(description: "One short sentence stating what happened, using only the window.")
    var text: String
    @Guide(description: "The id of the one segment in the window that best supports this bullet: the number after # at the start of its line.")
    var segmentID: Int
}
