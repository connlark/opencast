import Foundation

nonisolated enum StreamingAudioCachePolicy {
    static func isEligible(_ url: URL, configuration: StreamingAudioCacheConfiguration) -> Bool {
        guard configuration.isEnabled,
              configuration.directory != nil,
              !url.isFileURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return false
        }

        return url.pathExtension.lowercased() != "m3u8"
    }
}
