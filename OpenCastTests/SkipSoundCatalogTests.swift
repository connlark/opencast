import AVFoundation
import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Skip sound catalog")
struct SkipSoundCatalogTests {
    @Test("The catalog lists Vinyl Scratch, Rewind, Cassette and Guitar Riff in that order")
    func catalogListsTheSoundsInOrder() {
        #expect(SkipSoundCatalog.sounds.map(\.id) == ["vinyl-scratch", "rewind", "cassette", "guitar-riff"])
        #expect(SkipSoundCatalog.sounds.map(\.name) == ["Vinyl Scratch", "Rewind", "Cassette", "Guitar Riff"])
    }

    @Test("Each id finds its own sound")
    func eachIDFindsItsSound() {
        for sound in SkipSoundCatalog.sounds {
            #expect(SkipSoundCatalog.sound(id: sound.id) == sound)
        }
    }

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

    @Test("A sound whose file the bundle lacks is not listed and has no URL")
    func missingFileDropsItsSound() throws {
        let directory = URL.temporaryDirectory.appending(
            path: "SkipSoundCatalogTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for id in ["vinyl-scratch", "cassette"] {
            let source = try #require(Bundle.main.url(forResource: id, withExtension: "m4a"))
            try FileManager.default.copyItem(at: source, to: directory.appending(path: "\(id).m4a"))
        }
        let bundle = try #require(Bundle(url: directory))

        #expect(SkipSoundCatalog.availableSounds(in: bundle).map(\.id) == ["vinyl-scratch", "cassette"])
        let rewind = try #require(SkipSoundCatalog.sound(id: "rewind"))
        #expect(SkipSoundCatalog.url(for: rewind, in: bundle) == nil)
        let cassette = try #require(SkipSoundCatalog.sound(id: "cassette"))
        #expect(SkipSoundCatalog.url(for: cassette, in: bundle)?.lastPathComponent == "cassette.m4a")
    }
}
