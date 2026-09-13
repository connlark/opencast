import AppIntents

@AppEnum(schema: .audio.playbackAttributes)
nonisolated enum OpenCastAudioPlaybackAttribute: String {
    case shuffle
    case `repeat`
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.shuffle: "Shuffle", .repeat: "Repeat"]
}
