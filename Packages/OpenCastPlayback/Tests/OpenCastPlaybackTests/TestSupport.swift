import Foundation
@preconcurrency import MediaPlayer
import OpenCastCore
@testable import OpenCastPlayback

func episode(id: String = "episode", duration: TimeInterval?, artworkURL: URL? = nil) -> Episode {
    Episode(
        id: EpisodeID(rawValue: id),
        podcastID: PodcastID(rawValue: "podcast"),
        podcastTitle: "Podcast Title",
        title: "Episode Title",
        duration: duration,
        audioURL: URL(string: "https://example.com/audio.mp3"),
        artworkURL: artworkURL
    )
}

func doubleValue(_ value: Any?) -> Double? {
    if let value = value as? Double {
        return value
    }
    if let value = value as? Float {
        return Double(value)
    }
    return (value as? NSNumber)?.doubleValue
}

func floatValue(_ value: Any?) -> Float? {
    if let value = value as? Float {
        return value
    }
    if let value = value as? Double {
        return Float(value)
    }
    return (value as? NSNumber)?.floatValue
}
