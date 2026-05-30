#if DEBUG
import Foundation

enum AppStoreScreenshotSeedAudio {
    static func write() throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "opencast-app-store-screenshot-audio.wav")
        let sampleRate: UInt32 = 8_000
        let durationSeconds = 300
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sampleCount = Int(sampleRate) * durationSeconds
        let bytesPerSample = UInt16(MemoryLayout<Int16>.size)
        let blockAlign = channelCount * bytesPerSample
        let byteRate = sampleRate * UInt32(blockAlign)
        let audioByteCount = UInt32(sampleCount) * UInt32(blockAlign)

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(36 + audioByteCount, to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(channelCount, to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(byteRate, to: &data)
        appendLittleEndian(blockAlign, to: &data)
        appendLittleEndian(bitsPerSample, to: &data)
        data.append(contentsOf: "data".utf8)
        appendLittleEndian(audioByteCount, to: &data)

        for sampleIndex in 0..<sampleCount {
            let phase = Double(sampleIndex) / Double(sampleRate)
            let primary = sin(phase * 440 * 2 * .pi)
            let overtone = sin(phase * 660 * 2 * .pi) * 0.35
            let sample = Int16(((primary + overtone) * 0.16) * Double(Int16.max))
            appendLittleEndian(sample, to: &data)
        }

        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
#endif
