import Foundation

/// The synchronized `OpenCast/Resources/SkipSounds/` group is copied to the bundle's root, so
/// the lookup names no subdirectory.
enum SkipSoundCatalog {
    static let sounds = [
        SkipSound(id: "vinyl-scratch", name: "Vinyl Scratch"),
        SkipSound(id: "rewind", name: "Rewind"),
        SkipSound(id: "cassette", name: "Cassette"),
        SkipSound(id: "guitar-riff", name: "Guitar Riff"),
    ]

    /// Not in `sounds`: the listener's own file lives in `CustomSkipSoundFiles`.
    nonisolated static let customID = "custom"

    private static let fileExtension = "m4a"

    static func sound(id: String) -> SkipSound? {
        sounds.first { $0.id == id }
    }

    static func url(for sound: SkipSound, in bundle: Bundle) -> URL? {
        bundle.url(forResource: sound.id, withExtension: fileExtension)
    }

    static func availableSounds(in bundle: Bundle) -> [SkipSound] {
        sounds.filter { url(for: $0, in: bundle) != nil }
    }
}
