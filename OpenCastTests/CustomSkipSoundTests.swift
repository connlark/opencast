import AVFoundation
import Foundation
import os
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Custom skip sound")
struct CustomSkipSoundTests {
    @Test("A short audio file is copied in under a fresh name, chosen, handed to the controller and played once")
    func importingAShortFileStoresAndChoosesIt() async throws {
        let fixture = try Fixture()
        let source = try fixture.writeTone(named: "Door Chime.wav", seconds: 0.5)
        let store = fixture.makeStore()
        store.load(modelContext: fixture.context, playback: fixture.playback)

        let didImport = try await store.importCustomSkipSound(
            from: source,
            modelContext: fixture.context,
            playback: fixture.playback
        )

        #expect(didImport)
        let custom = try #require(store.customSkipSound)
        #expect(custom.name == "Door Chime")
        #expect(custom.fileName.hasPrefix("custom-"))
        #expect(custom.fileName.hasSuffix(".wav"))
        #expect(UUID(uuidString: String(custom.fileName.dropFirst("custom-".count).dropLast(".wav".count))) != nil)
        #expect(store.autoSkipSound == SkipSound(id: "custom", name: "Door Chime"))
        #expect(store.lastErrorMessage == nil)
        let customURL = fixture.files.url(forFileName: custom.fileName)
        #expect(try fixture.storedFileNames() == [custom.fileName])
        #expect(try Data(contentsOf: customURL) == Data(contentsOf: source))
        #expect(fixture.playback.appliedAutoSkipCues == [nil, customURL])
        #expect(fixture.playback.previewedAutoSkipCues == [customURL])
        #expect(try fixture.preference(PlaybackSettingsStore.autoSkipSoundPreferenceKey) == "custom")
        #expect(try fixture.preference(PlaybackSettingsStore.customSkipSoundFilePreferenceKey) == custom.fileName)
        #expect(try fixture.preference(PlaybackSettingsStore.customSkipSoundNamePreferenceKey) == "Door Chime")

        let reloadedPlayback = PlaybackVoiceBoostControllerSpy()
        let reloadedStore = fixture.makeStore()
        reloadedStore.load(modelContext: ModelContext(fixture.container), playback: reloadedPlayback)
        #expect(reloadedStore.autoSkipSound == custom.skipSound)
        #expect(reloadedPlayback.appliedAutoSkipCues == [customURL])
        #expect(reloadedPlayback.previewedAutoSkipCues.isEmpty)
    }

    @Test(
        "A file over 3 seconds, over the size cap or not audio is refused with nothing written and the earlier sound kept",
        arguments: RefusedSkipSoundFile.allCases
    )
    func refusedFileChangesNothing(refused: RefusedSkipSoundFile) async throws {
        let fixture = try Fixture()
        let durationLoads = DurationLoadRecorder()
        let store = fixture.makeStore(loadDuration: refused == .overSize ? durationLoads.loader : nil)
        store.load(modelContext: fixture.context, playback: fixture.playback)
        let earlier = try await fixture.importTone(named: "Earlier", into: store)
        let earlierURL = fixture.files.url(forFileName: earlier.fileName)
        let loadsBefore = await durationLoads.count
        let callsBefore = fixture.playback.autoSkipCalls
        let previewsBefore = fixture.playback.previewedAutoSkipCues
        let storedBefore = try fixture.customPreferences()
        let source = try refused.write(in: fixture)

        await #expect(throws: refused.expectedError) {
            try await store.importCustomSkipSound(from: source, modelContext: fixture.context, playback: fixture.playback)
        }

        #expect(refused.expectedError.message == refused.expectedMessage)
        #expect(try fixture.storedFileNames() == [earlier.fileName])
        #expect(FileManager.default.fileExists(atPath: earlierURL.path))
        #expect(store.customSkipSound == earlier)
        #expect(store.autoSkipSound == earlier.skipSound)
        #expect(fixture.playback.autoSkipCalls == callsBefore)
        #expect(fixture.playback.previewedAutoSkipCues == previewsBefore)
        #expect(try fixture.customPreferences() == storedBefore)
        // The cap is checked before the file is opened as audio.
        #expect(await durationLoads.count == loadsBefore)
    }

    @Test("Replacing the sound deletes the earlier file and gives the controller a different URL")
    func replacingDeletesTheEarlierFile() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.load(modelContext: fixture.context, playback: fixture.playback)
        let first = try await fixture.importTone(named: "Ding", into: store)
        let firstURL = fixture.files.url(forFileName: first.fileName)

        let second = try await fixture.importTone(named: "Ding", into: store)

        let secondURL = fixture.files.url(forFileName: second.fileName)
        #expect(second.fileName != first.fileName)
        #expect(secondURL != firstURL)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(try fixture.storedFileNames() == [second.fileName])
        #expect(store.customSkipSound == second)
        #expect(fixture.playback.appliedAutoSkipCues == [nil, firstURL, secondURL])
        #expect(fixture.playback.previewedAutoSkipCues == [firstURL, secondURL])
        #expect(try fixture.preference(PlaybackSettingsStore.customSkipSoundFilePreferenceKey) == second.fileName)
    }

    @Test("Deleting the sound removes its file and preferences, and a chosen one leaves None and no cue", arguments: [true, false])
    func removalDeletesTheFileAndPreferences(wasChosen: Bool) async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.load(modelContext: fixture.context, playback: fixture.playback)
        let custom = try await fixture.importTone(named: "Bell", into: store)
        let rewind = try #require(SkipSoundCatalog.sound(id: "rewind"))
        let rewindURL = try #require(SkipSoundCatalog.url(for: rewind, in: .main))
        if !wasChosen {
            store.setAutoSkipSound(rewind, modelContext: fixture.context, playback: fixture.playback)
        }
        let callsBefore = fixture.playback.autoSkipCalls

        #expect(store.removeCustomSkipSound(modelContext: fixture.context, playback: fixture.playback))

        #expect(store.customSkipSound == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.files.url(forFileName: custom.fileName).path))
        #expect(try fixture.storedFileNames().isEmpty)
        #expect(try fixture.preference(PlaybackSettingsStore.customSkipSoundFilePreferenceKey) == "")
        #expect(try fixture.preference(PlaybackSettingsStore.customSkipSoundNamePreferenceKey) == "")
        if wasChosen {
            #expect(store.autoSkipSound == nil)
            #expect(fixture.playback.autoSkipCalls == callsBefore + [.cue(nil)])
            #expect(try fixture.preference(PlaybackSettingsStore.autoSkipSoundPreferenceKey) == "")
        } else {
            #expect(store.autoSkipSound == rewind)
            #expect(fixture.playback.autoSkipCalls == callsBefore)
            #expect(try fixture.preference(PlaybackSettingsStore.autoSkipSoundPreferenceKey) == "rewind")
        }

        let reloadedPlayback = PlaybackVoiceBoostControllerSpy()
        let reloadedStore = fixture.makeStore()
        reloadedStore.load(modelContext: ModelContext(fixture.container), playback: reloadedPlayback)
        reloadedStore.loadCustomSkipSound(modelContext: ModelContext(fixture.container))
        #expect(reloadedStore.customSkipSound == nil)
        #expect(reloadedPlayback.appliedAutoSkipCues == [wasChosen ? nil : rewindURL])
    }

    @Test("The custom sound chosen with its file missing loads as None, and the picker shows no custom sound")
    func chosenCustomSoundWithoutItsFileReadsAsNone() throws {
        let fixture = try Fixture()
        try fixture.storeCustomPreferences(choice: "custom", fileName: "custom-\(UUID().uuidString).wav", name: "Gone")
        let store = fixture.makeStore()

        store.load(modelContext: fixture.context, playback: fixture.playback)

        #expect(store.autoSkipSound == nil)
        #expect(store.customSkipSound == nil)
        #expect(fixture.playback.appliedAutoSkipCues == [nil])
        store.loadCustomSkipSound(modelContext: fixture.context)
        #expect(store.customSkipSound == nil)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("A failed save keeps the earlier sound, its file and the cue, and leaves no new file")
    func saveFailureKeepsTheEarlierSound() async throws {
        let fixture = try Fixture()
        let saves = SaveSwitch()
        let store = fixture.makeStore(save: saves.save)
        store.load(modelContext: fixture.context, playback: fixture.playback)
        let earlier = try await fixture.importTone(named: "Earlier", into: store)
        let earlierURL = fixture.files.url(forFileName: earlier.fileName)
        let callsBefore = fixture.playback.autoSkipCalls
        let previewsBefore = fixture.playback.previewedAutoSkipCues
        let storedBefore = try fixture.customPreferences()
        let source = try fixture.writeTone(named: "Later.wav", seconds: 0.4)
        saves.fails = true

        let didImport = try await store.importCustomSkipSound(
            from: source,
            modelContext: fixture.context,
            playback: fixture.playback
        )

        #expect(!didImport)
        #expect(store.lastErrorMessage?.contains("Unable to add the sound") == true)
        #expect(store.customSkipSound == earlier)
        #expect(store.autoSkipSound == earlier.skipSound)
        #expect(try fixture.storedFileNames() == [earlier.fileName])
        #expect(FileManager.default.fileExists(atPath: earlierURL.path))
        #expect(fixture.playback.autoSkipCalls == callsBefore)
        #expect(fixture.playback.previewedAutoSkipCues == previewsBefore)
        #expect(try fixture.customPreferences() == storedBefore)

        saves.fails = false
        try fixture.context.save()
        let reloadedPlayback = PlaybackVoiceBoostControllerSpy()
        let reloadedStore = fixture.makeStore()
        reloadedStore.load(modelContext: ModelContext(fixture.container), playback: reloadedPlayback)
        #expect(reloadedStore.autoSkipSound == earlier.skipSound)
        #expect(reloadedPlayback.appliedAutoSkipCues == [earlierURL])
    }

    @Test("Auto-Skip off passes no cue and keeps the custom choice without looking for its file")
    func autoSkipOffKeepsTheCustomChoice() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.load(modelContext: fixture.context, playback: fixture.playback)
        store.setAutoSkipPromosAndAdsEnabled(false, modelContext: fixture.context, playback: fixture.playback)

        let custom = try await fixture.importTone(named: "Quiet", into: store)

        let customURL = fixture.files.url(forFileName: custom.fileName)
        #expect(store.autoSkipSound == custom.skipSound)
        #expect(fixture.playback.appliedAutoSkipCues.last == .some(nil))
        #expect(!fixture.playback.appliedAutoSkipCues.contains(customURL))
        #expect(fixture.playback.previewedAutoSkipCues == [customURL])

        store.setAutoSkipPromosAndAdsEnabled(true, modelContext: fixture.context, playback: fixture.playback)
        #expect(fixture.playback.autoSkipCalls.suffix(2) == [.cue(customURL), .enabled(true)])
        store.setAutoSkipPromosAndAdsEnabled(false, modelContext: fixture.context, playback: fixture.playback)

        // With the file gone, a store loaded while Auto-Skip is off still
        // reads the choice: it never looked for the file.
        try FileManager.default.removeItem(at: customURL)
        let offPlayback = PlaybackVoiceBoostControllerSpy()
        let offStore = fixture.makeStore()
        offStore.load(modelContext: ModelContext(fixture.container), playback: offPlayback)
        #expect(offStore.autoSkipSound == custom.skipSound)
        #expect(offPlayback.appliedAutoSkipCues == [nil])

        offStore.setAutoSkipPromosAndAdsEnabled(true, modelContext: ModelContext(fixture.container), playback: offPlayback)
        #expect(offStore.autoSkipSound == nil)
        #expect(offPlayback.appliedAutoSkipCues == [nil, nil])
    }

    @Test("Up to 3.0 seconds is kept; longer, empty, unreadable or unopenable audio is refused", arguments: [
        (3.0, nil),
        (3.001, CustomSkipSoundImportError.tooLong),
        (0, .unplayable),
        (.nan, .unplayable),
        (-1, .unplayable),
    ] as [(TimeInterval, CustomSkipSoundImportError?)])
    func durationLimit(duration: TimeInterval, expectedError: CustomSkipSoundImportError?) async throws {
        let fixture = try Fixture()
        let files = CustomSkipSoundFiles(directory: fixture.directory, loadDuration: { _ in duration })
        let source = fixture.sources.appending(path: "Anything.m4a")
        try Data("bytes".utf8).write(to: source)

        let result: Result<CustomSkipSound, CustomSkipSoundImportError>
        do {
            result = .success(try await files.importSound(from: source))
        } catch {
            result = .failure(error)
        }

        switch result {
        case .success(let imported):
            #expect(expectedError == nil)
            #expect(imported.name == "Anything")
            #expect(imported.fileName.hasSuffix(".m4a"))
            #expect(try fixture.storedFileNames() == [imported.fileName])
        case .failure(let error):
            #expect(error == expectedError)
            #expect(try fixture.storedFileNames().isEmpty)
        }
    }

    @Test("A loader that cannot open the file refuses it as unplayable")
    func unopenableFileIsUnplayable() async throws {
        let fixture = try Fixture()
        let files = CustomSkipSoundFiles(directory: fixture.directory, loadDuration: { _ in throw CocoaError(.fileReadCorruptFile) })
        let source = fixture.sources.appending(path: "Broken.caf")
        try Data("bytes".utf8).write(to: source)

        await #expect(throws: CustomSkipSoundImportError.unplayable) {
            try await files.importSound(from: source)
        }
        #expect(try fixture.storedFileNames().isEmpty)
    }

    @Test("A short file's length is what decodes, and up to 3.0 seconds is kept", arguments: [0.5, 3.0])
    func shortFileLengthIsWhatDecodes(seconds: Double) async throws {
        let fixture = try Fixture()
        let source = try fixture.writeTone(named: "Tone.wav", seconds: seconds)

        #expect(try await CustomSkipSoundFiles.audioDuration(of: source) == seconds)
        let imported = try await fixture.files.importSound(from: source)
        #expect(try fixture.storedFileNames() == [imported.fileName])
    }

    @Test("Decoding stops within one chunk past 3.0 seconds, and the file is refused as too long", arguments: [3.05, 20])
    func decodingStopsJustPastTheCap(seconds: Double) async throws {
        let fixture = try Fixture()
        let source = try fixture.writeTone(named: "Long.wav", seconds: seconds)
        let oneChunk = Double(CustomSkipSoundFiles.decodeChunkFrames) / Fixture.toneSampleRate

        let decoded = try await CustomSkipSoundFiles.audioDuration(of: source)

        #expect(decoded > CustomSkipSoundFiles.maximumDuration)
        #expect(decoded <= CustomSkipSoundFiles.maximumDuration + oneChunk)
        await #expect(throws: CustomSkipSoundImportError.tooLong) {
            try await fixture.files.importSound(from: source)
        }
        #expect(try fixture.storedFileNames().isEmpty)
    }

    @Test("A compressed file whose header reports a short length but whose audio does not decode is unplayable", arguments: BrokenAACFile.allCases)
    func undecodableCompressedFileIsUnplayable(broken: BrokenAACFile) async throws {
        let fixture = try Fixture()
        let source = try fixture.writeBrokenAAC(broken, named: "Broken.m4a", seconds: 0.45)
        let reported = try fixture.reportedDuration(of: source)
        #expect(reported > 0)
        #expect(reported <= CustomSkipSoundFiles.maximumDuration)

        await #expect(throws: CustomSkipSoundImportError.unplayable) {
            try await fixture.files.importSound(from: source)
        }
        #expect(try fixture.storedFileNames().isEmpty)
    }

    @Test("An MP3 whose header reports half a second but which decodes to 3.5 seconds is refused as too long")
    func underReportedLengthIsRefusedByWhatDecodes() async throws {
        let fixture = try Fixture()
        let source = try fixture.writeSilentMP3(named: "Short Header.mp3", claimedFrames: 20, frames: 135)
        let reported = try fixture.reportedDuration(of: source)
        #expect(abs(reported - 20 * 1_152 / Fixture.toneSampleRate) < 0.001)

        #expect(try await CustomSkipSoundFiles.audioDuration(of: source) > CustomSkipSoundFiles.maximumDuration)
        await #expect(throws: CustomSkipSoundImportError.tooLong) {
            try await fixture.files.importSound(from: source)
        }
        #expect(try fixture.storedFileNames().isEmpty)
    }

    @Test("A staging write that fails partway leaves no partial file")
    func failedStagingWriteLeavesNoPartialFile() async throws {
        let fixture = try Fixture()
        let stagedURL = OSAllocatedUnfairLock<URL?>(initialState: nil)
        let files = CustomSkipSoundFiles(directory: fixture.directory, writeStagedCopy: { data, url in
            stagedURL.withLock { $0 = url }
            try data.prefix(1_024).write(to: url)
            throw POSIXError(.EFBIG)
        })
        let source = try fixture.writeTone(named: "Partial.wav", seconds: 0.5)

        await #expect(throws: CustomSkipSoundImportError.fileOperationFailed(POSIXError(.EFBIG).localizedDescription)) {
            try await files.importSound(from: source)
        }

        let staged = try #require(stagedURL.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(try fixture.storedFileNames().isEmpty)
    }

    @Test("Opening the picker deletes files nothing references and keeps the referenced one", arguments: [true, false])
    func pickerLoadDeletesUnreferencedFiles(hasSound: Bool) async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.load(modelContext: fixture.context, playback: fixture.playback)
        var kept: CustomSkipSound?
        if hasSound {
            kept = try await fixture.importTone(named: "Kept", into: store)
        }
        let stray = try fixture.writeStrayFile()

        let pickerStore = fixture.makeStore()
        pickerStore.loadCustomSkipSound(modelContext: ModelContext(fixture.container))

        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(try fixture.storedFileNames() == (kept.map { [$0.fileName] } ?? []))
        #expect(pickerStore.customSkipSound == kept)
        #expect(pickerStore.lastErrorMessage == nil)
    }

    @Test("An import deletes files nothing references")
    func importDeletesUnreferencedFiles() async throws {
        let fixture = try Fixture()
        let store = fixture.makeStore()
        store.load(modelContext: fixture.context, playback: fixture.playback)
        let stray = try fixture.writeStrayFile()

        let imported = try await fixture.importTone(named: "New", into: store)

        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(try fixture.storedFileNames() == [imported.fileName])
    }

    @Test("While an import is in flight the picker's read deletes nothing, and the import's own sweep follows")
    func pickerLoadDuringAnImportDeletesNothing() async throws {
        let fixture = try Fixture()
        let gate = DurationLoaderGate()
        let store = fixture.makeStore(loadDuration: gate.loader)
        store.load(modelContext: fixture.context, playback: fixture.playback)
        let stray = try fixture.writeStrayFile()
        let source = try fixture.writeTone(named: "Slow.wav", seconds: 0.5)
        let importing = Task {
            try await store.importCustomSkipSound(from: source, modelContext: fixture.context, playback: fixture.playback)
        }
        await gate.waitUntilEntered()

        store.loadCustomSkipSound(modelContext: fixture.context)
        #expect(FileManager.default.fileExists(atPath: stray.path))

        await gate.release()
        #expect(try await importing.value)
        let imported = try #require(store.customSkipSound)
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(try fixture.storedFileNames() == [imported.fileName])
    }

    @Test("An import that Delete Data overtakes removes its file and changes nothing else")
    func importOvertakenByDeleteDataChangesNothing() async throws {
        let fixture = try Fixture()
        let gate = DurationLoaderGate()
        let store = fixture.makeStore(loadDuration: gate.loader)
        store.load(modelContext: fixture.context, playback: fixture.playback)
        let callsBefore = fixture.playback.autoSkipCalls
        let storedBefore = try fixture.customPreferences()
        let source = try fixture.writeTone(named: "Slow.wav", seconds: 0.5)
        let importing = Task {
            try await store.importCustomSkipSound(from: source, modelContext: fixture.context, playback: fixture.playback)
        }
        await gate.waitUntilEntered()

        store.resetAfterDataNuke()
        await gate.release()

        #expect(try await importing.value == false)
        #expect(try fixture.storedFileNames().isEmpty)
        #expect(try fixture.customPreferences() == storedBefore)
        #expect(store.autoSkipSound == nil)
        #expect(store.customSkipSound == nil)
        #expect(store.lastErrorMessage == nil)
        #expect(fixture.playback.autoSkipCalls == callsBefore)
        #expect(fixture.playback.previewedAutoSkipCues.isEmpty)
    }
}

/// Two ways a compressed file's audio fails to decode while its header
/// still reports a length.
enum BrokenAACFile: CaseIterable, Sendable {
    /// The audio bytes overwritten.
    case corrupted
    /// The file cut off halfway through its audio.
    case truncated
}

/// The three ways an import is refused.
enum RefusedSkipSoundFile: CaseIterable, Sendable {
    case tooLong
    case overSize
    case notAudio

    var expectedError: CustomSkipSoundImportError {
        switch self {
        case .tooLong: .tooLong
        case .overSize: .tooLarge
        case .notAudio: .unplayable
        }
    }

    var expectedMessage: String {
        switch self {
        case .tooLong, .overSize: "Sounds can be up to 3 seconds long."
        case .notAudio: "That file can't be played."
        }
    }

    @MainActor
    fileprivate func write(in fixture: Fixture) throws -> URL {
        switch self {
        case .tooLong:
            return try fixture.writeTone(named: "Long.wav", seconds: 3.5)
        case .overSize:
            // One byte over the cap; the duration loader would accept it.
            let url = fixture.sources.appending(path: "Huge.wav")
            #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(CustomSkipSoundFiles.maximumFileSize + 1))
            try handle.close()
            return url
        case .notAudio:
            let url = fixture.sources.appending(path: "Notes.mp3")
            try Data("These are notes, not audio.".utf8).write(to: url)
            return url
        }
    }
}

@MainActor
private struct Fixture {
    let container: ModelContainer
    let context: ModelContext
    let playback = PlaybackVoiceBoostControllerSpy()
    let directory: URL
    let sources: URL
    let files: CustomSkipSoundFiles

    init() throws {
        container = try OpenCastModelContainerFactory.make(inMemory: true)
        context = ModelContext(container)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CustomSkipSoundTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        directory = root.appending(path: CustomSkipSoundFiles.directoryName, directoryHint: .isDirectory)
        sources = root.appending(path: "Sources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        files = CustomSkipSoundFiles(directory: directory)
    }

    /// The real duration loader unless one is given.
    func makeStore(
        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
        loadDuration: (@Sendable (URL) async throws -> TimeInterval)? = nil
    ) -> PlaybackSettingsStore {
        PlaybackSettingsStore(
            save: save,
            customSkipSoundFiles: loadDuration.map { CustomSkipSoundFiles(directory: directory, loadDuration: $0) } ?? files
        )
    }

    func importTone(named name: String, into store: PlaybackSettingsStore) async throws -> CustomSkipSound {
        let source = try writeTone(named: "\(name).wav", seconds: 0.3)
        #expect(try await store.importCustomSkipSound(from: source, modelContext: context, playback: playback))
        return try #require(store.customSkipSound)
    }

    /// A 440 Hz tone as 16-bit PCM WAV, closed before it returns.
    func writeTone(named name: String, seconds: Double) throws -> URL {
        let url = sources.appending(path: name)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.toneSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
        )
        try file.write(from: toneBuffer(seconds: seconds))
        file.close()
        return url
    }

    /// The tone as AAC in an MPEG-4 file whose audio is then broken. Its
    /// header still opens and reports the tone's length.
    func writeBrokenAAC(_ broken: BrokenAACFile, named name: String, seconds: Double) throws -> URL {
        let url = sources.appending(path: name)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.toneSampleRate,
                AVNumberOfChannelsKey: 1,
            ]
        )
        try file.write(from: toneBuffer(seconds: seconds))
        file.close()

        var data = try Data(contentsOf: url)
        let audio = try #require(Self.mediaDataPayload(in: data))
        switch broken {
        case .corrupted:
            data.replaceSubrange(audio, with: Data(repeating: 0xFF, count: audio.count))
        case .truncated:
            data = data.prefix(audio.lowerBound + audio.count / 2)
        }
        try data.write(to: url)
        return url
    }

    /// Silent MPEG-1 Layer III frames (mono, 44.1 kHz, 128 kbit/s, 1,152
    /// samples each), led by a Xing header that counts only
    /// `claimedFrames` of them.
    func writeSilentMP3(named name: String, claimedFrames: UInt32, frames: Int) throws -> URL {
        // 144 × 128,000 / 44,100 bytes, unpadded; all-zero side info and
        // main data decode as silence.
        var frame = Data(count: 417)
        frame.replaceSubrange(0..<4, with: [0xFF, 0xFB, 0x90, 0xC4])
        var data = frame
        // The tag follows the 4-byte header and 17 bytes of mono side info:
        // "Xing", flags (frame count present), the frame count.
        let frameCount = withUnsafeBytes(of: claimedFrames.bigEndian) { Array($0) }
        let tag: [UInt8] = Array("Xing".utf8) + [0, 0, 0, 1] + frameCount
        data.replaceSubrange(21..<21 + tag.count, with: tag)
        for _ in 0..<frames {
            data.append(frame)
        }
        let url = sources.appending(path: name)
        try data.write(to: url)
        return url
    }

    /// The length the header reports, without decoding.
    func reportedDuration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// A file in the directory that no preference references, as a failed
    /// delete leaves one.
    func writeStrayFile() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = files.url(forFileName: "custom-\(UUID().uuidString).wav")
        try Data("left behind".utf8).write(to: url)
        return url
    }

    static let toneSampleRate = 44_100.0

    private func toneBuffer(seconds: Double) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.toneSampleRate, channels: 1))
        let frameCount = AVAudioFrameCount(Self.toneSampleRate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(frameCount) {
            samples[frame] = Float(sin(2 * Double.pi * 440 * Double(frame) / Self.toneSampleRate) * 0.1)
        }
        return buffer
    }

    /// The byte range of the top-level `mdat` box's payload.
    private static func mediaDataPayload(in data: Data) -> Range<Int>? {
        var offset = 0
        while offset + 8 <= data.count {
            let size = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            if data[offset + 4..<offset + 8].elementsEqual("mdat".utf8) {
                return offset + 8..<min(offset + size, data.count)
            }
            guard size >= 8 else {
                return nil
            }
            offset += size
        }
        return nil
    }

    func storedFileNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func preference(_ key: String) throws -> String? {
        try LocalPreferenceRecord.preference(forKey: key, modelContext: context)?.value
    }

    /// The three preferences with their stamps, to show a failed write
    /// restored them exactly.
    func customPreferences() throws -> [String: String] {
        var stored: [String: String] = [:]
        for key in [
            PlaybackSettingsStore.autoSkipSoundPreferenceKey,
            PlaybackSettingsStore.customSkipSoundFilePreferenceKey,
            PlaybackSettingsStore.customSkipSoundNamePreferenceKey,
        ] {
            let record = try LocalPreferenceRecord.preference(forKey: key, modelContext: context)
            stored[key] = record.map { "\($0.value)@\($0.updatedAt.timeIntervalSinceReferenceDate)" }
        }
        return stored
    }

    func storeCustomPreferences(choice: String, fileName: String, name: String) throws {
        context.insert(LocalPreferenceRecord(key: PlaybackSettingsStore.autoSkipSoundPreferenceKey, value: choice))
        context.insert(LocalPreferenceRecord(key: PlaybackSettingsStore.customSkipSoundFilePreferenceKey, value: fileName))
        context.insert(LocalPreferenceRecord(key: PlaybackSettingsStore.customSkipSoundNamePreferenceKey, value: name))
        try context.save()
    }
}

/// Counts the files the duration loader is asked about, and accepts each.
private actor DurationLoadRecorder {
    private(set) var count = 0

    nonisolated var loader: @Sendable (URL) async throws -> TimeInterval {
        { [self] _ in await record() }
    }

    private func record() -> TimeInterval {
        count += 1
        return 1
    }
}

/// A duration loader that, once entered, waits until the test releases it,
/// so the test can act while an import is in flight. It then accepts the
/// file.
private actor DurationLoaderGate {
    private var isEntered = false
    private var isReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated var loader: @Sendable (URL) async throws -> TimeInterval {
        { [self] _ in
            await enterAndWait()
            return 1
        }
    }

    func waitUntilEntered() async {
        guard !isEntered else {
            return
        }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        isReleased = true
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters = []
    }

    private func enterAndWait() async {
        isEntered = true
        for waiter in entryWaiters {
            waiter.resume()
        }
        entryWaiters = []
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
}

@MainActor
private final class SaveSwitch {
    var fails = false

    func save(_ context: ModelContext) throws {
        if fails {
            throw SimulatedSaveFailure()
        }
        try context.save()
    }
}

private struct SimulatedSaveFailure: LocalizedError {
    var errorDescription: String? {
        "Simulated preference save failure"
    }
}
