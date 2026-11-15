import Foundation

/// The listener's own skip sound: its file in `CustomSkipSoundFiles`'
/// directory and the name the picker shows, the imported file's name.
nonisolated struct CustomSkipSound: Hashable, Sendable {
    let fileName: String
    let name: String

    /// The sound as the picker and the stored choice know it.
    var skipSound: SkipSound {
        SkipSound(id: SkipSoundCatalog.customID, name: name)
    }
}
