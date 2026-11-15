import Foundation

/// The Skip Sound picker's sounds, in its order. Each is `<id>.m4a` in the
/// app bundle; the synchronized `OpenCast/Resources/SkipSounds/` group is
/// copied to the bundle's root, so the lookup names no subdirectory.
enum SkipSoundCatalog {
    static let sounds = [
        SkipSound(id: "vinyl-scratch", name: "Vinyl Scratch"),
        SkipSound(id: "rewind", name: "Rewind"),
        SkipSound(id: "cassette", name: "Cassette"),
        SkipSound(id: "guitar-riff", name: "Guitar Riff"),
    ]

    /// The stored choice for the listener's own sound, which is not in
    /// `sounds`: its file is in `CustomSkipSoundFiles`, not the bundle.
    nonisolated static let customID = "custom"

    private static let fileExtension = "m4a"

    /// Nil for an empty or unknown id, such as a sound a later build removed,
    /// and for `customID`. Reads no file.
    static func sound(id: String) -> SkipSound? {
        sounds.first { $0.id == id }
    }

    /// Nil when the bundle does not carry the sound's file.
    static func url(for sound: SkipSound, in bundle: Bundle) -> URL? {
        bundle.url(forResource: sound.id, withExtension: fileExtension)
    }

    /// The sounds whose files the bundle carries, in the catalog's order.
    static func availableSounds(in bundle: Bundle) -> [SkipSound] {
        sounds.filter { url(for: $0, in: bundle) != nil }
    }
}
