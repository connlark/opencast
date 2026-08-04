#if DEBUG
import Foundation

enum AppStoreScreenshotSeedAudio {
    static func write() throws -> URL {
        try PCM16WAVWriter.write(
            to: FileManager.default.temporaryDirectory.appending(path: "opencast-app-store-screenshot-audio.wav")
        ) { phase in
            let primary = sin(phase * 440 * 2 * .pi)
            let overtone = sin(phase * 660 * 2 * .pi) * 0.35
            return (primary + overtone) * 0.16
        }
    }
}
#endif
