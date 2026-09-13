import AppIntents

// The SDK macro copies explicit nonisolated onto a synthesized typealias.
// An enclosing nonisolated namespace keeps the generated union conformance
// off MainActor without applying that invalid modifier to the typealias.
nonisolated enum OpenCastAudioItem {
    @UnionValue
    enum Value {
        case episode(OpenCastEpisodeEntity)
        case show(OpenCastPodcastEntity)

        static var typeDisplayRepresentation: TypeDisplayRepresentation { "Podcast Content" }
        static let caseDisplayRepresentations: [Cases: DisplayRepresentation] = [.episode: "Episode", .show: "Show"]
    }
}
