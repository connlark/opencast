import AVFoundation
import CoreML
import Foundation
import Testing
@testable import OpenCastTranscription
@preconcurrency import WhisperKit

/// The spilled-PCM audio path must be
/// bit-identical to the in-memory `[Float]` path it replaces — the spill
/// file's samples vs `loadAudioAsFloatArray`, and every window served by
/// `PCMFileAudioSampleSource` vs the `padOrTrimAudio` array copy, including
/// nil parity for out-of-range requests. Set OPENCAST_TRANSCRIPTION_AUDIO to
/// also gate a real multi-chunk episode spill.
@Suite("Windowed audio source equivalence")
struct WindowedAudioSourceTests {
    // MARK: Fixtures

    private func temporaryAudioPlaceholder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("wav")
        try Data("not audio".utf8).write(to: url)
        return url
    }

    private func makeFixture(sampleRate: Double, channels: AVAudioChannelCount, seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "g2-fixture-\(Int(sampleRate))hz-\(channels)ch-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false) else {
            throw WhisperError.loadAudioFailed("Unable to create fixture format")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw WhisperError.loadAudioFailed("Unable to create fixture buffer")
        }
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frameCount) {
                let time = Double(frame) / sampleRate
                let tone = sin(2 * .pi * (220 + 35 * Double(channel)) * time)
                let drift = sin(2 * .pi * 3.1 * time + Double(channel))
                data[frame] = Float(tone * 0.4 + drift * 0.1)
            }
        }
        buffer.frameLength = frameCount
        try file.write(from: buffer)
        return url
    }

    private func spilledSamples(fromPath path: String, startTime: Double? = 0, endTime: Double? = nil) throws -> [Float] {
        let spillURL = FileManager.default.temporaryDirectory
            .appending(path: "g2-spill-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: spillURL) }
        let count = try AudioProcessor.spillAudioToPCMFile(
            fromPath: path,
            startTime: startTime,
            endTime: endTime,
            to: spillURL
        )
        let data = try Data(contentsOf: spillURL)
        #expect(data.count == count * MemoryLayout<Float>.stride)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func expectBitIdentical(_ produced: [Float], _ reference: [Float], _ label: String) {
        #expect(produced.count == reference.count, "\(label): count \(produced.count) vs \(reference.count)")
        guard produced.count == reference.count else { return }
        let mismatch = produced.indices.first { produced[$0].bitPattern != reference[$0].bitPattern }
        #expect(mismatch == nil, "\(label): first bit mismatch at sample \(mismatch ?? -1)")
    }

    private func windowArray(_ output: (any AudioProcessorOutputType)?) -> [Float]? {
        guard let array = output as? MLMultiArray else { return nil }
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: pointer, count: array.count))
    }

    // MARK: Spill pass equivalence

    @Test("Spilled PCM matches loadAudioAsFloatArray (16 kHz mono)")
    func spillMatchesLoaderDirectRead() throws {
        let url = try makeFixture(sampleRate: 16000, channels: 1, seconds: 70)
        defer { try? FileManager.default.removeItem(at: url) }

        let reference = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        expectBitIdentical(try spilledSamples(fromPath: url.path), reference, "16k mono full")

        let clippedReference = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path, startTime: 10.25, endTime: 42.5)
        expectBitIdentical(
            try spilledSamples(fromPath: url.path, startTime: 10.25, endTime: 42.5),
            clippedReference,
            "16k mono clipped"
        )
    }

    @Test("Spilled PCM matches loadAudioAsFloatArray (44.1 kHz stereo resample)")
    func spillMatchesLoaderResamplePath() throws {
        let url = try makeFixture(sampleRate: 44100, channels: 2, seconds: 70)
        defer { try? FileManager.default.removeItem(at: url) }

        let reference = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        expectBitIdentical(try spilledSamples(fromPath: url.path), reference, "44.1k stereo full")

        let clippedReference = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path, startTime: 10.25, endTime: 42.5)
        expectBitIdentical(
            try spilledSamples(fromPath: url.path, startTime: 10.25, endTime: 42.5),
            clippedReference,
            "44.1k stereo clipped"
        )
    }

    @Test(
        "Opt-in: real episode multi-chunk spill matches the loader",
        .timeLimit(.minutes(10)),
        .enabled(if: ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPTION_AUDIO"] != nil)
    )
    func realEpisodeSpillMatchesLoader() throws {
        let audioPath = try #require(ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPTION_AUDIO"])

        let reference = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
        expectBitIdentical(try spilledSamples(fromPath: audioPath), reference, "episode full")
    }

    // MARK: Window serving equivalence

    @Test("File-served windows match padOrTrimAudio for every window shape")
    func fileServedWindowsMatchPadOrTrim() throws {
        // Deterministic non-repeating content; long enough for interior,
        // straddling, and trailing windows at a small window size.
        let sampleCount = 100_000
        var samples = [Float](repeating: 0, count: sampleCount)
        for index in 0..<sampleCount {
            let phase = Double(index)
            let tone: Double = sin(phase * 0.0137) * 0.6
            let drift: Double = cos(phase * 0.0031) * 0.3
            samples[index] = Float(tone + drift)
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "g2-windows-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: fileURL)

        let source = try PCMFileAudioSampleSource(fileURL: fileURL, expectedSampleCount: sampleCount)
        #expect(source.sampleCount == sampleCount)

        let windowLength = 16_000
        let cases: [(label: String, startAt: Int, availableLength: Int)] = [
            ("window at start", 0, windowLength),
            ("interior window", 30_000, windowLength),
            ("cold start mid-file (resume shape)", 54_321, windowLength),
            ("unaligned start", 12_345, windowLength),
            ("clip end bounds the copy", 30_000, 9_876),
            ("availableLength beyond window", 30_000, 50_000),
            ("trailing window needs padding", sampleCount - 5_000, 5_000),
            ("availableLength overshoots the end", sampleCount - 5_000, windowLength),
            ("single sample", sampleCount - 1, 1),
        ]
        for testCase in cases {
            let served = windowArray(
                try source.windowSamples(
                    startAt: testCase.startAt,
                    availableLength: testCase.availableLength,
                    toLength: windowLength
                )
            )
            let reference = windowArray(
                AudioProcessor.padOrTrimAudio(
                    fromArray: samples,
                    startAt: testCase.startAt,
                    availableLength: testCase.availableLength,
                    toLength: windowLength
                )
            )
            let servedArray = try #require(served, "\(testCase.label): served window is nil")
            let referenceArray = try #require(reference, "\(testCase.label): reference window is nil")
            expectBitIdentical(servedArray, referenceArray, testCase.label)
        }
    }

    @Test("Out-of-range requests return nil exactly like padOrTrimAudio")
    func outOfRangeRequestsMatchPadOrTrimNilParity() throws {
        let sampleCount = 1_000
        let samples = (0..<sampleCount).map { Float($0) / Float(sampleCount) }
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "g2-nilparity-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: fileURL)

        let source = try PCMFileAudioSampleSource(fileURL: fileURL)
        let cases: [(label: String, startAt: Int, availableLength: Int)] = [
            ("negative start", -1, 100),
            ("start at count", sampleCount, 100),
            ("start beyond count", sampleCount + 5, 100),
            ("zero available length", 0, 0),
            ("negative available length", 0, -3),
        ]
        for testCase in cases {
            let served = try source.windowSamples(startAt: testCase.startAt, availableLength: testCase.availableLength, toLength: 200)
            let reference = AudioProcessor.padOrTrimAudio(
                fromArray: samples,
                startAt: testCase.startAt,
                availableLength: testCase.availableLength,
                toLength: 200
            )
            #expect(served == nil, "\(testCase.label): served should be nil")
            #expect(reference == nil, "\(testCase.label): reference should be nil")
        }
    }

    @Test("Sample-count validation rejects truncated spill files")
    func sampleCountValidationRejectsTruncatedFiles() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "g2-truncated-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let samples = [Float](repeating: 0.5, count: 100)
        try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: fileURL)

        #expect(throws: WhisperError.self) {
            _ = try PCMFileAudioSampleSource(fileURL: fileURL, expectedSampleCount: 101)
        }
        // A file with a partial trailing sample is rejected outright.
        let partialURL = FileManager.default.temporaryDirectory
            .appending(path: "g2-partial-\(UUID().uuidString).pcm")
        defer { try? FileManager.default.removeItem(at: partialURL) }
        try Data([0x01, 0x02, 0x03]).write(to: partialURL)
        #expect(throws: WhisperError.self) {
            _ = try PCMFileAudioSampleSource(fileURL: partialURL)
        }
    }

    // MARK: Service spill lifecycle

    @Test("Long-form run removes its spill file on completion")
    func longFormRunRemovesSpillFileOnCompletion() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        let loader = DestinationRecordingAudioLoader(
            samples: Array(repeating: 0.25, count: Int(WhisperKit.sampleRate) * 40)
        )
        let service = OpenCastTranscriptionService(
            modelLocator: RecordingModelLocator(),
            runtimeLoader: RecordingRuntimeLoader(log: TranscriptionEventLog()),
            audioLoader: loader
        )
        let request = OpenCastLongFormTranscriptionRequest(
            audioFileURL: audioURL,
            sourceAudioURL: "https://example.com/audio.mp3",
            sourceFileByteCount: 10,
            sourceFileSHA256: "source-sha",
            modelIdentifier: "model-a",
            modelVersion: "v1",
            modelTreeSHA256: "tree-sha"
        )

        var didFinish = false
        for try await event in await service.transcribe(request) {
            if case .finished = event {
                didFinish = true
            }
        }
        #expect(didFinish)

        let destination = try #require(loader.recordedDestinations.first)
        #expect(!FileManager.default.fileExists(atPath: destination.path), "spill file must be removed after completion")
    }

    @Test("Cancelled long-form run removes its spill file")
    func cancelledLongFormRunRemovesSpillFile() async throws {
        let audioURL = try temporaryAudioPlaceholder()
        let loader = DestinationRecordingAudioLoader(
            samples: Array(repeating: 0.25, count: Int(WhisperKit.sampleRate) * 40)
        )
        let service = OpenCastTranscriptionService(
            modelLocator: RecordingModelLocator(),
            runtimeLoader: RecordingRuntimeLoader(log: TranscriptionEventLog(), decodeDelay: .seconds(30)),
            audioLoader: loader
        )
        let request = OpenCastLongFormTranscriptionRequest(
            audioFileURL: audioURL,
            sourceAudioURL: "https://example.com/audio.mp3",
            sourceFileByteCount: 10,
            sourceFileSHA256: "source-sha",
            modelIdentifier: "model-a",
            modelVersion: "v1",
            modelTreeSHA256: "tree-sha"
        )

        // Abandon the stream at the first event; termination cancels the run
        // mid-decode (the runtime holds the decode open for 30 s).
        for try await _ in await service.transcribe(request) {
            break
        }

        let destination = try #require(loader.recordedDestinations.first)
        var removed = false
        for _ in 0..<200 {
            if !FileManager.default.fileExists(atPath: destination.path) {
                removed = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(removed, "spill file must be removed after cancellation")
    }
}

/// Loader fake that records the spill destinations it was handed, so
/// lifecycle tests can assert cleanup without racing other suites' spills.
final class DestinationRecordingAudioLoader: OpenCastTranscriptionAudioLoading, @unchecked Sendable {
    private let samples: [Float]
    private let lock = NSLock()
    private var destinations: [URL] = []

    init(samples: [Float]) {
        self.samples = samples
    }

    var recordedDestinations: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return destinations
    }

    func samples(from audioFileURL: URL, clipStart: TimeInterval, clipDuration: TimeInterval?) async throws -> [Float] {
        try Task.checkCancellation()
        return samples
    }

    private func record(_ destination: URL) {
        lock.lock()
        destinations.append(destination)
        lock.unlock()
    }

    func spillSamples(from audioFileURL: URL, clipStart: TimeInterval, clipDuration: TimeInterval?, to destination: URL) async throws -> Int {
        record(destination)
        try Task.checkCancellation()
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: destination)
        return samples.count
    }
}
