import AVFoundation
import Accelerate
import Foundation
import Testing
@preconcurrency import WhisperKit

/// E2 gate (whisper-perf pass 2): the direct-copy audio load path must
/// produce identical sample counts and bit-identical samples to the upstream
/// chunked implementation it replaced. The upstream conversion (1,024-frame
/// temporaries + source zeroing) is preserved here as the reference.
/// Set OPENCAST_TRANSCRIPTION_AUDIO=<mp3> to also gate a real multi-chunk
/// episode load (the 10-minute chunk loop only exercises multiple chunks on
/// long inputs).
@Suite("Audio load direct copy equivalence")
struct AudioLoadDirectCopyTests {
    // MARK: Upstream reference implementations

    private func referenceConvertBufferToArray(buffer: AVAudioPCMBuffer, chunkSize: Int = 1024) -> [Float] {
        guard let channelData = buffer.floatChannelData else {
            return []
        }

        let frameLength = Int(buffer.frameLength)
        let startPointer = channelData[0]
        var result: [Float] = []
        result.reserveCapacity(frameLength)

        var currentFrame = 0
        while currentFrame < frameLength {
            let remainingFrames = frameLength - currentFrame
            let currentChunkSize = min(chunkSize, remainingFrames)

            var chunk = [Float](repeating: 0, count: currentChunkSize)

            chunk.withUnsafeMutableBufferPointer { bufferPointer in
                vDSP_mmov(
                    startPointer.advanced(by: currentFrame),
                    bufferPointer.baseAddress!,
                    vDSP_Length(currentChunkSize),
                    1,
                    vDSP_Length(currentChunkSize),
                    1
                )
            }

            result.append(contentsOf: chunk)
            currentFrame += currentChunkSize

            memset(startPointer.advanced(by: currentFrame - currentChunkSize), 0, currentChunkSize * MemoryLayout<Float>.size)
        }

        return result
    }

    private func referenceLoadAudioAsFloatArray(
        fromPath audioFilePath: String,
        startTime: Double? = 0,
        endTime: Double? = nil
    ) throws -> [Float] {
        let audioFileURL = URL(fileURLWithPath: audioFilePath)
        let audioFile = try AVAudioFile(forReading: audioFileURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let inputSampleRate = audioFile.fileFormat.sampleRate
        let inputDuration = Double(AVAudioFrameCount(audioFile.length)) / inputSampleRate

        let start = startTime ?? 0
        let end = min(endTime ?? inputDuration, inputDuration)

        let chunkDuration: Double = 60 * 10
        var currentTime = start
        var result: [Float] = []

        while currentTime < end {
            let chunkEnd = min(currentTime + chunkDuration, end)

            try autoreleasepool {
                let buffer = try AudioProcessor.loadAudio(
                    fromFile: audioFile,
                    channelMode: .sumChannels(nil),
                    startTime: currentTime,
                    endTime: chunkEnd
                )

                let floatArray = referenceConvertBufferToArray(buffer: buffer)
                result.append(contentsOf: floatArray)
            }

            currentTime = chunkEnd
        }

        return result
    }

    // MARK: Fixtures

    /// Deterministic multi-tone content; distinct per channel so channel
    /// summing is exercised.
    private func makeFixture(sampleRate: Double, channels: AVAudioChannelCount, seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "e2-fixture-\(Int(sampleRate))hz-\(channels)ch-\(UUID().uuidString).wav")
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

    private func expectBitIdentical(_ produced: [Float], _ reference: [Float], _ label: String) {
        #expect(produced.count == reference.count, "\(label): count \(produced.count) vs \(reference.count)")
        guard produced.count == reference.count else { return }
        let mismatch = produced.indices.first { produced[$0].bitPattern != reference[$0].bitPattern }
        #expect(mismatch == nil, "\(label): first bit mismatch at sample \(mismatch ?? -1)")
    }

    // MARK: Gates

    @Test("convertBufferToArray matches the upstream chunked conversion")
    func convertBufferMatchesReference() throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw WhisperError.loadAudioFailed("Unable to create format")
        }
        // Zero, sub-chunk, exact-chunk, and non-multiple-of-chunk lengths.
        for frames in [0, 1000, 1024, 100_000] {
            guard let productionBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))),
                  let referenceBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))) else {
                throw WhisperError.loadAudioFailed("Unable to create buffers")
            }
            for frame in 0..<frames {
                let value = Float(sin(Double(frame) * 0.017)) * 0.7
                productionBuffer.floatChannelData![0][frame] = value
                referenceBuffer.floatChannelData![0][frame] = value
            }
            productionBuffer.frameLength = AVAudioFrameCount(frames)
            referenceBuffer.frameLength = AVAudioFrameCount(frames)

            // The reference zeroes its source as it copies, so it gets its own buffer.
            let produced = AudioProcessor.convertBufferToArray(buffer: productionBuffer)
            let reference = referenceConvertBufferToArray(buffer: referenceBuffer)
            expectBitIdentical(produced, reference, "convert frames=\(frames)")
        }
    }

    @Test("Direct-read path (16 kHz mono) matches the upstream loader")
    func directReadPathMatchesReference() throws {
        let url = try makeFixture(sampleRate: 16000, channels: 1, seconds: 70)
        defer { try? FileManager.default.removeItem(at: url) }

        let full = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        let fullReference = try referenceLoadAudioAsFloatArray(fromPath: url.path)
        expectBitIdentical(full, fullReference, "16k mono full")

        let clipped = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path, startTime: 10.25, endTime: 42.5)
        let clippedReference = try referenceLoadAudioAsFloatArray(fromPath: url.path, startTime: 10.25, endTime: 42.5)
        expectBitIdentical(clipped, clippedReference, "16k mono clipped")
    }

    @Test("Resample path (44.1 kHz stereo) matches the upstream loader")
    func resamplePathMatchesReference() throws {
        let url = try makeFixture(sampleRate: 44100, channels: 2, seconds: 70)
        defer { try? FileManager.default.removeItem(at: url) }

        let full = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        let fullReference = try referenceLoadAudioAsFloatArray(fromPath: url.path)
        expectBitIdentical(full, fullReference, "44.1k stereo full")

        let clipped = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path, startTime: 10.25, endTime: 42.5)
        let clippedReference = try referenceLoadAudioAsFloatArray(fromPath: url.path, startTime: 10.25, endTime: 42.5)
        expectBitIdentical(clipped, clippedReference, "44.1k stereo clipped")
    }

    @Test("Opt-in: real episode multi-chunk load matches the upstream loader", .timeLimit(.minutes(10)))
    func realEpisodeMatchesReference() throws {
        guard let audioPath = ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPTION_AUDIO"] else {
            return
        }

        let full = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
        let fullReference = try referenceLoadAudioAsFloatArray(fromPath: audioPath)
        expectBitIdentical(full, fullReference, "episode full")

        // Straddles a 10-minute chunk boundary from a non-zero start.
        let clipped = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath, startTime: 37.5, endTime: 1200.5)
        let clippedReference = try referenceLoadAudioAsFloatArray(fromPath: audioPath, startTime: 37.5, endTime: 1200.5)
        expectBitIdentical(clipped, clippedReference, "episode clipped")
    }

    // MARK: Opt-in host probe (OPENCAST_AUDIO_LOAD_PROBE=1)

    private func currentFootprintBytes() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(info.phys_footprint)
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    /// Footprint peak is sampled at 10 ms cadence on the host — directional
    /// evidence; the device A/B's harness fields are the verdict metric.
    /// Peak-footprint comparisons need one load per process (freed pages get
    /// reused, masking later peaks): set OPENCAST_AUDIO_LOAD_PROBE_VARIANT
    /// and OPENCAST_AUDIO_LOAD_PROBE_WORKLOAD for single-shot mode and drive
    /// fresh processes from the shell.
    @Test("Opt-in: host timing/footprint probe, production vs upstream loader", .timeLimit(.minutes(15)))
    func hostLoadProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENCAST_AUDIO_LOAD_PROBE"] == "1",
              let audioPath = environment["OPENCAST_TRANSCRIPTION_AUDIO"] else {
            return
        }

        let allWorkloads: [(label: String, start: Double?, end: Double?)] = [
            ("clip30", 0, 30),
            ("clip600", 0, 600),
            ("full", nil, nil),
        ]
        let singleVariant = environment["OPENCAST_AUDIO_LOAD_PROBE_VARIANT"]
        let singleWorkload = environment["OPENCAST_AUDIO_LOAD_PROBE_WORKLOAD"]
        let workloads = allWorkloads.filter { singleWorkload == nil || $0.label == singleWorkload }
        let variants = singleVariant.map { [$0] } ?? ["production", "reference"]
        let repeats = singleVariant == nil ? 3 : 1

        for workload in workloads {
            // Alternate implementations within each workload so allocator
            // warmup and file-cache state don't favor one side.
            for repeatIndex in 0..<repeats {
                for variant in variants {
                    let footprintStart = currentFootprintBytes() ?? 0
                    let sampler = ProbeFootprintSampler(initial: footprintStart)
                    sampler.start()

                    let cpuStart = cpuSeconds()
                    let clock = ContinuousClock()
                    let start = clock.now
                    let samples: [Float] =
                        if variant == "production" {
                            try AudioProcessor.loadAudioAsFloatArray(
                                fromPath: audioPath, startTime: workload.start, endTime: workload.end
                            )
                        } else {
                            try referenceLoadAudioAsFloatArray(
                                fromPath: audioPath, startTime: workload.start, endTime: workload.end
                            )
                        }
                    let wall = start.duration(to: clock.now)
                    let cpu = cpuSeconds() - cpuStart
                    let peakBytes = sampler.stop(finalSample: currentFootprintBytes())

                    let wallSeconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
                    let peakDeltaMB = Double(peakBytes - footprintStart) / 1_048_576
                    print("AUDIO_LOAD_PROBE workload=\(workload.label) variant=\(variant) repeat=\(repeatIndex) samples=\(samples.count) wall_s=\(String(format: "%.4f", wallSeconds)) cpu_s=\(String(format: "%.4f", cpu)) peak_delta_mb=\(String(format: "%.1f", peakDeltaMB))")
                }
            }
        }
    }
}

/// 10 ms footprint sampler for the opt-in host probe.
private final class ProbeFootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int64
    private var task: Task<Void, Never>?

    init(initial: Int64) {
        peak = initial
    }

    func start() {
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func stop(finalSample: Int64?) -> Int64 {
        task?.cancel()
        task = nil
        lock.lock()
        defer { lock.unlock() }
        if let finalSample {
            peak = max(peak, finalSample)
        }
        return peak
    }

    private func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        lock.lock()
        peak = max(peak, Int64(info.phys_footprint))
        lock.unlock()
    }
}
