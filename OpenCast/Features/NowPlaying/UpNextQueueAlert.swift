enum UpNextQueueAlert {
    case queue(String)
    case playback(String)

    var title: String {
        switch self {
        case .queue:
            "Up Next Error"
        case .playback:
            "Playback Failed"
        }
    }

    var message: String {
        switch self {
        case .queue(let message), .playback(let message):
            message
        }
    }
}
