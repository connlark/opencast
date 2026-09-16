/// What survived citation validation: bullets whose segment id resolves to a
/// segment the model was actually shown, plus the ones that were dropped so
/// the caller can decide whether enough remains to display.
nonisolated struct TranscriptRecapValidation: Equatable, Sendable {
    var bullets: [TranscriptRecapResultBullet]
    var droppedBullets: [TranscriptRecapBullet]

    var droppedCount: Int {
        droppedBullets.count
    }
}
