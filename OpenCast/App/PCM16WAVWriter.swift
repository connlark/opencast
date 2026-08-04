import Foundation

/// Byte-deterministic PCM16 WAV writer for seeded audio fixtures. Not
/// `#if DEBUG` — the UI-test seed caller compiles in Release — and
/// deliberately not `AVAudioFile`: the manual header keeps the fixtures
/// byte-identical, which the perf baselines rely on.
enum PCM16WAVWriter {
    static func write(
        to fileURL: URL,
        sampleRate: UInt32 = 8_000,
        durationSeconds: Int = 300,
        sample: (_ phase: Double) -> Double
    ) throws -> URL {
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
            appendLittleEndian(Int16(sample(phase) * Double(Int16.max)), to: &data)
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
