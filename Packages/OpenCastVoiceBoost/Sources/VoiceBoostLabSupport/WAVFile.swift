import Foundation

enum WAVFile {
    static func read(_ url: URL) throws -> WAVAudio {
        let data = try Data(contentsOf: url)
        guard data.count >= 12,
              data.asciiString(in: 0..<4) == "RIFF",
              data.asciiString(in: 8..<12) == "WAVE"
        else {
            throw LabError.invalidWAV("Missing RIFF/WAVE header.")
        }

        var offset = 12
        var audioFormat: UInt16?
        var channelCount: Int?
        var sampleRate: Double?
        var bitsPerSample: UInt16?
        var dataRange: Range<Int>?

        while offset + 8 <= data.count {
            let chunkID = data.asciiString(in: offset..<(offset + 4))
            let chunkSize = Int(data.uint32LE(at: offset + 4))
            let chunkStart = offset + 8
            let chunkEnd = chunkStart + chunkSize
            guard chunkEnd <= data.count else {
                throw LabError.invalidWAV("Chunk extends past end of file.")
            }

            switch chunkID {
            case "fmt ":
                guard chunkSize >= 16 else {
                    throw LabError.invalidWAV("fmt chunk is too small.")
                }
                audioFormat = data.uint16LE(at: chunkStart)
                channelCount = Int(data.uint16LE(at: chunkStart + 2))
                sampleRate = Double(data.uint32LE(at: chunkStart + 4))
                bitsPerSample = data.uint16LE(at: chunkStart + 14)
            case "data":
                dataRange = chunkStart..<chunkEnd
            default:
                break
            }

            offset = chunkEnd + (chunkSize.isMultiple(of: 2) ? 0 : 1)
        }

        guard let audioFormat, let channelCount, let sampleRate, let bitsPerSample, let dataRange else {
            throw LabError.invalidWAV("Missing fmt or data chunk.")
        }
        guard (1...2).contains(channelCount) else {
            throw LabError.invalidWAV("Only mono and stereo WAV files are supported.")
        }

        let samples: [Float]
        switch (audioFormat, bitsPerSample) {
        case (1, 16):
            samples = try readPCM16(data: data, range: dataRange)
        case (3, 32):
            samples = try readFloat32(data: data, range: dataRange)
        default:
            throw LabError.invalidWAV("Only 16-bit PCM and 32-bit float WAV files are supported.")
        }

        guard samples.count.isMultiple(of: channelCount) else {
            throw LabError.invalidWAV("Data chunk does not align to channel count.")
        }

        return WAVAudio(sampleRate: sampleRate, channelCount: channelCount, samples: samples)
    }

    static func write(_ audio: WAVAudio, to url: URL) throws {
        var data = Data()
        let dataByteCount = UInt32(audio.samples.count * MemoryLayout<Float>.size)
        let formatByteCount: UInt32 = 16
        let riffByteCount = UInt32(4 + 8 + formatByteCount + 8) + dataByteCount

        data.appendASCII("RIFF")
        data.appendUInt32LE(riffByteCount)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendUInt32LE(formatByteCount)
        data.appendUInt16LE(3)
        data.appendUInt16LE(UInt16(audio.channelCount))
        data.appendUInt32LE(UInt32(audio.sampleRate.rounded()))
        data.appendUInt32LE(UInt32(audio.sampleRate.rounded()) * UInt32(audio.channelCount) * 4)
        data.appendUInt16LE(UInt16(audio.channelCount * 4))
        data.appendUInt16LE(32)
        data.appendASCII("data")
        data.appendUInt32LE(dataByteCount)

        for sample in audio.samples {
            var littleEndianSample = sample
            withUnsafeBytes(of: &littleEndianSample) { bytes in
                data.append(contentsOf: bytes)
            }
        }

        try data.write(to: url, options: .atomic)
    }

    private static func readPCM16(data: Data, range: Range<Int>) throws -> [Float] {
        guard range.count.isMultiple(of: 2) else {
            throw LabError.invalidWAV("16-bit PCM data has odd byte count.")
        }

        var samples: [Float] = []
        samples.reserveCapacity(range.count / 2)

        var offset = range.lowerBound
        while offset < range.upperBound {
            let raw = Int16(bitPattern: data.uint16LE(at: offset))
            samples.append(max(-1, Float(raw) / 32_768))
            offset += 2
        }

        return samples
    }

    private static func readFloat32(data: Data, range: Range<Int>) throws -> [Float] {
        guard range.count.isMultiple(of: 4) else {
            throw LabError.invalidWAV("Float32 data does not align to 4 bytes.")
        }

        var samples: [Float] = []
        samples.reserveCapacity(range.count / 4)

        var offset = range.lowerBound
        while offset < range.upperBound {
            let bits = data.uint32LE(at: offset)
            samples.append(Float(bitPattern: bits))
            offset += 4
        }

        return samples
    }
}

private extension Data {
    func asciiString(in range: Range<Int>) -> String {
        String(decoding: self[range], as: UTF8.self)
    }

    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset])
            | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
