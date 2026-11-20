import AVFoundation
import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Skip sound catalog")
struct SkipSoundCatalogTests {
    @Test("An empty, unknown or display-name id finds no sound", arguments: ["", "removed-sound", "Rewind"])
    func unknownIDFindsNoSound(id: String) {
        #expect(SkipSoundCatalog.sound(id: id) == nil)
    }

    @Test("Every sound the app bundle carries opens, stays short and carries no metadata")
    func bundledSoundsOpenStayShortAndCarryNoMetadata() async throws {
        let sounds = SkipSoundCatalog.availableSounds(in: .main)
        #expect(sounds.contains { $0.id == "vinyl-scratch" }, "Vinyl Scratch must ship, so this check never passes on no sounds")

        for sound in sounds {
            let url = try #require(SkipSoundCatalog.url(for: sound, in: .main))
            let player = try AVAudioPlayer(contentsOf: url)
            let limit: TimeInterval = sound.id == "guitar-riff" ? 2.2 : 1.5
            #expect(player.duration > 0, "\(sound.id) has no audio")
            #expect(player.duration <= limit, "\(sound.id) lasts \(player.duration) s, over \(limit) s")

            let metadata = try await AVURLAsset(url: url).load(.metadata)
            #expect(metadata.isEmpty, "\(sound.id) carries \(metadata.count) metadata items")
        }
    }
}
