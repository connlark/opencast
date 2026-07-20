@preconcurrency import AVFoundation
import Foundation
@testable import OpenCastPlayback

/// Builds `AudioBufferList`s over Swift arrays so runtime-state tests can
/// exercise the tap process path without a live `MTAudioProcessingTap`.
enum AudioBufferListFixture {
    @discardableResult
    static func processInterleaved(
        state: inout VoiceBoostAudioTapRuntimeState,
        samples: inout [Float],
        channelCount: Int,
        frameOffset: Int,
        frameCount: Int
    ) -> VoiceBoostTapProcessOutcome {
        samples.withUnsafeMutableBufferPointer { pointer in
            let offsetSamples = frameOffset * channelCount
            let sampleCount = frameCount * channelCount
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channelCount),
                    mDataByteSize: UInt32(sampleCount * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(pointer.baseAddress! + offsetSamples)
                )
            )
            return state.process(bufferList: &bufferList, frameCount: frameCount)
        }
    }

    @discardableResult
    static func processPlanar(
        state: inout VoiceBoostAudioTapRuntimeState,
        left: inout [Float],
        right: inout [Float],
        frameOffset: Int,
        frameCount: Int
    ) -> VoiceBoostTapProcessOutcome {
        left.withUnsafeMutableBufferPointer { leftPointer in
            right.withUnsafeMutableBufferPointer { rightPointer in
                let bufferList = AudioBufferList.allocate(maximumBuffers: 2)
                defer {
                    free(bufferList.unsafeMutablePointer)
                }

                let byteCount = UInt32(frameCount * MemoryLayout<Float>.size)
                bufferList[0] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: byteCount,
                    mData: UnsafeMutableRawPointer(leftPointer.baseAddress! + frameOffset)
                )
                bufferList[1] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: byteCount,
                    mData: UnsafeMutableRawPointer(rightPointer.baseAddress! + frameOffset)
                )
                return state.process(
                    bufferList: bufferList.unsafeMutablePointer,
                    frameCount: frameCount
                )
            }
        }
    }
}
