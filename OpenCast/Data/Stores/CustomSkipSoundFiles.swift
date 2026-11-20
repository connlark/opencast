@preconcurrency import AVFoundation
import Foundation

/// Each import gets a fresh file name: the player ignores a cue URL it already holds, so a file
/// replaced at the same path would keep the old sound.
nonisolated struct CustomSkipSoundFiles: Sendable {
    static let directoryName = "CustomSkipSounds"
    static let maximumDuration: TimeInterval = 3
    /// 3 s of 192 kHz 32-bit PCM in 8 channels is 18,432,000 bytes, so no common 3-second sound
    /// reaches this; a larger file is refused before it is read in full.
    static let maximumFileSize = 20_000_000
    /// A file over the duration cap is decoded at most this far past it.
    static let decodeChunkFrames: AVAudioFrameCount = 4096

    let directory: URL
    private let loadDuration: @Sendable (URL) async throws -> TimeInterval
    private let writeStagedCopy: @Sendable (Data, URL) throws -> Void

    init(
        directory: URL = .applicationSupportDirectory.appending(path: directoryName, directoryHint: .isDirectory),
        loadDuration: @escaping @Sendable (URL) async throws -> TimeInterval = CustomSkipSoundFiles.audioDuration(of:),
        writeStagedCopy: @escaping @Sendable (Data, URL) throws -> Void = CustomSkipSoundFiles.writeStagedCopy(_:to:)
    ) {
        self.directory = directory
        self.loadDuration = loadDuration
        self.writeStagedCopy = writeStagedCopy
    }

    func url(forFileName fileName: String) -> URL {
        directory.appending(path: fileName)
    }

    func fileExists(named fileName: String) -> Bool {
        Self.isFileName(fileName) && FileManager.default.fileExists(atPath: url(forFileName: fileName).path)
    }

    @concurrent
    func importSound(from source: URL) async throws(CustomSkipSoundImportError) -> CustomSkipSound {
        let data = try Self.readSource(source)
        let fileName = Self.newFileName(extension: source.pathExtension)
        let stagedURL = URL.temporaryDirectory.appending(path: fileName)
        do {
            try writeStagedCopy(data, stagedURL)
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw .fileOperationFailed(error.localizedDescription)
        }

        do {
            try await validate(stagedURL)
            try moveIntoPlace(stagedURL, fileName: fileName)
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }
        return CustomSkipSound(fileName: fileName, name: Self.displayName(for: source))
    }

    func removeFile(named fileName: String) throws {
        guard Self.isFileName(fileName) else {
            return
        }
        try Self.removeItemIfPresent(at: url(forFileName: fileName))
    }

    func removeFiles(except fileName: String?) throws {
        let fileNames: [String]
        do {
            fileNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        }
        for name in fileNames where name != fileName {
            try Self.removeItemIfPresent(at: url(forFileName: name))
        }
    }

    func removeAll() throws {
        try Self.removeItemIfPresent(at: directory)
    }

    /// Decodes rather than trusting the header: a header can under-report the length, and a corrupt
    /// file can report one and decode nothing. No `AVAudioPlayer`: preparing one takes the audio
    /// session.
    @concurrent
    static func audioDuration(of url: URL) async throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: decodeChunkFrames)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let frameLimit = AVAudioFramePosition(maximumDuration * sampleRate)
        var decodedFrames: AVAudioFramePosition = 0
        while decodedFrames <= frameLimit {
            try Task.checkCancellation()
            do {
                try file.read(into: buffer)
            } catch let error as NSError where error.code == Int(kAudioFileEndOfFileError) {
                // A read at the end throws rather than returning no frames.
                break
            }
            guard buffer.frameLength > 0 else {
                break
            }
            decodedFrames += AVAudioFramePosition(buffer.frameLength)
        }
        return Double(decodedFrames) / sampleRate
    }

    static func writeStagedCopy(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func validate(_ url: URL) async throws(CustomSkipSoundImportError) {
        let duration: TimeInterval
        do {
            duration = try await loadDuration(url)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .unplayable
        }
        guard duration.isFinite, duration > 0 else {
            throw .unplayable
        }
        guard duration <= Self.maximumDuration else {
            throw .tooLong
        }
    }

    private func moveIntoPlace(_ stagedURL: URL, fileName: String) throws(CustomSkipSoundImportError) {
        do {
            try LocalBackupExclusion.apply(to: directory)
            try FileManager.default.moveItem(at: stagedURL, to: url(forFileName: fileName))
        } catch {
            throw .fileOperationFailed(error.localizedDescription)
        }
    }

    /// Reads at most one byte past the cap, so a large file is never read whole.
    private static func readSource(_ source: URL) throws(CustomSkipSoundImportError) -> Data {
        let isAccessing = source.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                source.stopAccessingSecurityScopedResource()
            }
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
        } catch {
            throw .fileOperationFailed(error.localizedDescription)
        }
        guard data.count <= maximumFileSize else {
            throw .tooLarge
        }
        return data
    }

    private static func newFileName(extension originalExtension: String) -> String {
        let stem = "custom-\(UUID().uuidString)"
        var safeExtension = ""
        for scalar in originalExtension.unicodeScalars.prefix(12) where CharacterSet.alphanumerics.contains(scalar) {
            safeExtension.unicodeScalars.append(scalar)
        }
        return safeExtension.isEmpty ? stem : "\(stem).\(safeExtension)"
    }

    private static func displayName(for source: URL) -> String {
        let name = source.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Custom Sound" : name
    }

    /// The stored name is only ever one this type made; anything that could
    /// reach outside the directory is treated as no file.
    private static func isFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty && !fileName.contains("/") && fileName != "." && fileName != ".."
    }

    private static func removeItemIfPresent(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
        }
    }
}
