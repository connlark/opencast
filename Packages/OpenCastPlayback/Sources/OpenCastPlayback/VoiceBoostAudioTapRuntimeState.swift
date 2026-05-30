@preconcurrency import AVFoundation
import AudioToolbox
import OpenCastVoiceBoost

nonisolated struct VoiceBoostAudioTapRuntimeState {
    var configuration: VoiceBoostConfiguration
    // VoiceBoostProcessor has no internal synchronization; every access is serialized by VoiceBoostAudioTapContext.stateLock.
    var processor: VoiceBoostProcessor?
    var channelCount = 0
    var isFloat32 = false
    var isNonInterleaved = false
    var scratch: [Float] = []

    mutating func prepare(
        maximumFrames: Int,
        sampleRate: Double,
        channelCount: Int,
        isFloat32: Bool,
        isNonInterleaved: Bool,
        isSupported: Bool
    ) {
        self.channelCount = channelCount
        self.isFloat32 = isFloat32
        self.isNonInterleaved = isNonInterleaved

        guard isSupported else {
            processor = nil
            scratch.removeAll(keepingCapacity: false)
            return
        }

        processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: channelCount,
            configuration: configuration
        )
        scratch = Array(repeating: 0, count: maximumFrames * channelCount)
    }

    mutating func unprepare() {
        processor = nil
        scratch.removeAll(keepingCapacity: true)
    }

    mutating func update(configuration: VoiceBoostConfiguration) {
        self.configuration = configuration
        processor?.update(configuration: configuration)
    }

    func reset() {
        processor?.reset()
    }

    @discardableResult
    mutating func process(
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int
    ) -> Bool {
        guard configuration.isEnabled, let processor, frameCount > 0, isFloat32 else {
            return false
        }

        var buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        if isNonInterleaved {
            return processPlanar(buffers: &buffers, frameCount: frameCount, processor: processor)
        } else {
            return processInterleaved(buffers: &buffers, frameCount: frameCount, processor: processor)
        }
    }

    private func processInterleaved(
        buffers: inout UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        processor: VoiceBoostProcessor
    ) -> Bool {
        guard buffers.count == 1,
              buffers[0].mNumberChannels == channelCount,
              let data = buffers[0].mData
        else {
            return false
        }

        let sampleCount = frameCount * channelCount
        guard Int(buffers[0].mDataByteSize) >= sampleCount * MemoryLayout<Float>.size else {
            return false
        }

        let samples = data.assumingMemoryBound(to: Float.self)
        let buffer = UnsafeMutableBufferPointer(start: samples, count: sampleCount)
        processor.processInterleavedFloat32(buffer, frameCount: frameCount)
        return true
    }

    private mutating func processPlanar(
        buffers: inout UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        processor: VoiceBoostProcessor
    ) -> Bool {
        guard buffers.count >= channelCount else {
            return false
        }

        let sampleCount = frameCount * channelCount
        guard scratch.count >= sampleCount else {
            return false
        }

        for channel in 0..<channelCount {
            guard let data = buffers[channel].mData,
                  Int(buffers[channel].mDataByteSize) >= frameCount * MemoryLayout<Float>.size
            else {
                return false
            }

            let source = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                scratch[frame * channelCount + channel] = source[frame]
            }
        }

        scratch.withUnsafeMutableBufferPointer { buffer in
            processor.processInterleavedFloat32(
                UnsafeMutableBufferPointer(start: buffer.baseAddress, count: sampleCount),
                frameCount: frameCount
            )
        }

        for channel in 0..<channelCount {
            guard let data = buffers[channel].mData else {
                return false
            }

            let destination = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                destination[frame] = scratch[frame * channelCount + channel]
            }
        }
        return true
    }
}
