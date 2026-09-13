import AppIntents

@AppEnum(schema: .audio.queueInsertionLocation)
nonisolated enum OpenCastAudioQueueLocation: String {
    case next
    case tail
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.next: "Next", .tail: "Last"]
}
