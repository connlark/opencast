nonisolated struct TranscriptRecapValidation: Equatable, Sendable {
    var bullets: [TranscriptRecapResultBullet]
    var droppedBullets: [TranscriptRecapBullet]

    var droppedCount: Int {
        droppedBullets.count
    }
}
