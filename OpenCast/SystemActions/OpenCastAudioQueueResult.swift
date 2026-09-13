import AppIntents

@AppEntity(schema: .audio.warmupAudioQueueResult)
struct OpenCastAudioQueueResult {
    static let defaultQuery = OpenCastAudioQueueResultQuery()
    let id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Audio Queue") }
}
