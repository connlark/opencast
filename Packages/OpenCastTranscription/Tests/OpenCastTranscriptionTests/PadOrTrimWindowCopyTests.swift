import CoreML
import Foundation
import Testing
@preconcurrency import WhisperKit

/// B3 gate: the direct bounded window copy must be byte-equivalent to the
/// old slice-then-pad path for every window shape the seek loop produces.
@Suite("Pad-or-trim window copy")
struct PadOrTrimWindowCopyTests {
    private let windowSamples = 16

    private func rampAudio(count: Int) -> [Float] {
        (0..<count).map { Float($0) * 0.001 - 3 }
    }

    private func oldPath(_ audio: [Float], seek: Int, segmentSize: Int) -> Data? {
        let slice = Array(audio[seek..<(seek + segmentSize)])
        return AudioProcessor.padOrTrimAudio(fromArray: slice, startAt: 0, toLength: windowSamples, saveSegment: false)
            .map { $0.withUnsafeBytes { Data($0) } }
    }

    private func newPath(_ audio: [Float], seek: Int, segmentSize: Int) -> Data? {
        AudioProcessor.padOrTrimAudio(fromArray: audio, startAt: seek, availableLength: segmentSize, toLength: windowSamples)
            .map { $0.withUnsafeBytes { Data($0) } }
    }

    @Test("Full window at the start matches the slice path")
    func fullWindowAtStart() {
        let audio = rampAudio(count: 64)
        #expect(newPath(audio, seek: 0, segmentSize: windowSamples) == oldPath(audio, seek: 0, segmentSize: windowSamples))
    }

    @Test("Non-zero-start full window matches the slice path")
    func nonZeroStartFullWindow() {
        let audio = rampAudio(count: 64)
        #expect(newPath(audio, seek: 32, segmentSize: windowSamples) == oldPath(audio, seek: 32, segmentSize: windowSamples))
    }

    @Test("Short trailing window pads with zeros identically")
    func shortTrailingWindowPads() {
        let audio = rampAudio(count: 40)
        // Last window: seek 32, only 8 samples remain.
        let new = newPath(audio, seek: 32, segmentSize: 8)
        #expect(new == oldPath(audio, seek: 32, segmentSize: 8))
        let values = new.map { data in data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } } ?? []
        #expect(values.suffix(8).allSatisfy { $0 == 0 })
    }

    @Test("Clip end earlier than the array end bounds the copy")
    func clippedEndBoundsCopy() {
        let audio = rampAudio(count: 64)
        // seekClipEnd at 40 with seek 32: only 8 samples allowed even though
        // the array continues to 64. The old path sliced exactly this range.
        let new = newPath(audio, seek: 32, segmentSize: 8)
        #expect(new == oldPath(audio, seek: 32, segmentSize: 8))
        let values = new.map { data in data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } } ?? []
        #expect(values.count == windowSamples)
        #expect(values[7] == audio[39])
        #expect(values.suffix(8).allSatisfy { $0 == 0 })
    }

    @Test("Whole file shorter than one window matches the slice path")
    func wholeFileShorterThanWindow() {
        let audio = rampAudio(count: 10)
        #expect(newPath(audio, seek: 0, segmentSize: 10) == oldPath(audio, seek: 0, segmentSize: 10))
    }

    @Test("Available length beyond the array clamps to the array end")
    func availableLengthBeyondArrayClamps() {
        let audio = rampAudio(count: 20)
        // Old path cannot express this case (the slice would trap); the new
        // path must clamp to the array like the old segmentSize math did.
        let new = newPath(audio, seek: 12, segmentSize: windowSamples)
        let expected = oldPath(audio, seek: 12, segmentSize: 8)
        #expect(new == expected)
    }

    @Test("Out-of-range windows return nil like the slice path")
    func outOfRangeWindowsReturnNil() {
        let audio = rampAudio(count: 20)
        #expect(newPath(audio, seek: 20, segmentSize: 4) == nil)
        #expect(newPath(audio, seek: -1, segmentSize: 4) == nil)
        #expect(newPath(audio, seek: 0, segmentSize: 0) == nil)
    }
}
