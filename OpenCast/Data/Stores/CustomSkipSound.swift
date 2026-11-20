import Foundation

/// `fileName` is relative to `CustomSkipSoundFiles`' directory; `name` is the imported file's.
nonisolated struct CustomSkipSound: Hashable, Sendable {
    let fileName: String
    let name: String

    var skipSound: SkipSound {
        SkipSound(id: SkipSoundCatalog.customID, name: name)
    }
}
