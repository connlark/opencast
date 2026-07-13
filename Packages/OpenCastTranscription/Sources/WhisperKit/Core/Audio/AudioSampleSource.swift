//  For licensing see accompanying LICENSE.md file.
//  Copyright © 2024 Argmax, Inc. All rights reserved.

import Accelerate
import CoreML
import Foundation

/// OpenCast fork (whisper-perf G2): bounded-memory audio access for the
/// long-form decode loop. A source serves zero-padded decode windows with
/// the exact semantics of
/// `AudioProcessor.padOrTrimAudio(fromArray:startAt:availableLength:toLength:)`
/// without requiring every sample to stay resident for the whole run.
@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
public protocol AudioSampleSource: Sendable {
    /// Total number of 16 kHz mono samples this source can serve.
    var sampleCount: Int { get }

    /// Copies `[startIndex, startIndex + min(availableLength, frameLength))`
    /// into a `frameLength`-sized window, zero-padding the tail. Returns nil
    /// for out-of-range requests (parity with `padOrTrimAudio`).
    func windowSamples(
        startAt startIndex: Int,
        availableLength: Int,
        toLength frameLength: Int
    ) throws -> (any AudioProcessorOutputType)?
}

/// Array-backed source: the historical in-memory path. `padOrTrim(fromArray:)`
/// is a protocol-extension member that forwards to the static
/// `padOrTrimAudio`, so calling the static here is the identical window copy.
@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
struct ArrayAudioSampleSource: AudioSampleSource {
    let samples: [Float]

    var sampleCount: Int { samples.count }

    func windowSamples(
        startAt startIndex: Int,
        availableLength: Int,
        toLength frameLength: Int
    ) throws -> (any AudioProcessorOutputType)? {
        AudioProcessor.padOrTrimAudio(
            fromArray: samples,
            startAt: startIndex,
            availableLength: availableLength,
            toLength: frameLength
        )
    }
}

/// Serves decode windows from a spilled canonical PCM file (16 kHz mono
/// Float32, host byte order, as written by
/// `AudioProcessor.spillAudioToPCMFile`). Reads use `pread`, so requests are
/// position-independent: overlapping windows, fallback re-reads, and a cold
/// start at an arbitrary mid-file seek (resume) all behave like array access.
@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
public final class PCMFileAudioSampleSource: AudioSampleSource, @unchecked Sendable {
    // @unchecked: all stored state is immutable after init and pread carries
    // no shared file position.
    public let sampleCount: Int
    private let fileDescriptor: Int32

    /// - Parameter expectedSampleCount: when provided (from the spill pass),
    ///   the file length must match exactly — guards against truncated or
    ///   concurrently modified spill files.
    public init(fileURL: URL, expectedSampleCount: Int? = nil) throws {
        let descriptor = open(fileURL.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw WhisperError.loadAudioFailed("Unable to open PCM sample file \(fileURL.path) (errno \(errno))")
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let errorNumber = errno
            close(descriptor)
            throw WhisperError.loadAudioFailed("Unable to stat PCM sample file \(fileURL.path) (errno \(errorNumber))")
        }
        let byteCount = Int(status.st_size)
        let sampleStride = MemoryLayout<Float>.stride
        guard byteCount % sampleStride == 0 else {
            close(descriptor)
            throw WhisperError.loadAudioFailed("PCM sample file has a partial trailing sample (\(byteCount) bytes)")
        }
        let fileSampleCount = byteCount / sampleStride
        if let expectedSampleCount, expectedSampleCount != fileSampleCount {
            close(descriptor)
            throw WhisperError.loadAudioFailed("PCM sample file holds \(fileSampleCount) samples, expected \(expectedSampleCount)")
        }
        fileDescriptor = descriptor
        sampleCount = fileSampleCount
    }

    deinit {
        close(fileDescriptor)
    }

    public func windowSamples(
        startAt startIndex: Int,
        availableLength: Int,
        toLength frameLength: Int
    ) throws -> (any AudioProcessorOutputType)? {
        guard startIndex >= 0, startIndex < sampleCount, availableLength > 0 else {
            Logging.error("Audio window is outside the buffer size")
            return nil
        }

        let endFrameIndex = min(sampleCount, startIndex + min(availableLength, frameLength))
        let actualFrameLength = endFrameIndex - startIndex

        let audioSamplesArray = try MLMultiArray(shape: [NSNumber(value: frameLength)], dataType: .float32)
        let windowPointer = audioSamplesArray.dataPointer.assumingMemoryBound(to: Float.self)

        if actualFrameLength > 0 {
            let sampleStride = MemoryLayout<Float>.stride
            var destination = UnsafeMutableRawPointer(windowPointer)
            var byteOffset = off_t(startIndex) * off_t(sampleStride)
            var bytesRemaining = actualFrameLength * sampleStride
            while bytesRemaining > 0 {
                let bytesRead = pread(fileDescriptor, destination, bytesRemaining, byteOffset)
                if bytesRead < 0 {
                    if errno == EINTR { continue }
                    throw WhisperError.loadAudioFailed("PCM sample file read failed (errno \(errno))")
                }
                guard bytesRead > 0 else {
                    throw WhisperError.loadAudioFailed("PCM sample file ended early at byte offset \(byteOffset)")
                }
                destination += bytesRead
                byteOffset += off_t(bytesRead)
                bytesRemaining -= bytesRead
            }
        }

        if actualFrameLength < frameLength {
            vDSP_vclr(windowPointer.advanced(by: actualFrameLength), 1, vDSP_Length(frameLength - actualFrameLength))
        }

        return audioSamplesArray
    }
}
