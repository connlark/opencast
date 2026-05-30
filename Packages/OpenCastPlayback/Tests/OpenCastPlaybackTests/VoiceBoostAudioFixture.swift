@preconcurrency import AVFoundation
import Foundation

enum VoiceBoostAudioFixture {
    static func writeSine(
        fileExtension: String,
        settings: [String: Any]? = nil,
        duration: TimeInterval = 1.5
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "opencast-voiceboost-\(UUID().uuidString).\(fileExtension)")
        let sampleRate = 44_100.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let phase = 2 * Double.pi * 440 * Double(frame) / sampleRate
            samples[frame] = Float(sin(phase) * 0.12)
        }

        let file = try AVAudioFile(forWriting: url, settings: settings ?? format.settings)
        try file.write(from: buffer)
        return url
    }

    static func aacSettings(sampleRate: Double = 44_100.0) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
    }

    static func writeGeneratedMP3Sine(duration: TimeInterval = 1.0) throws -> URL {
        guard let ffmpegURL = ffmpegExecutableURL else {
            throw FixtureError.missingFFmpeg
        }

        let url = FileManager.default.temporaryDirectory
            .appending(path: "opencast-voiceboost-\(UUID().uuidString).mp3")
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-f", "lavfi",
            "-i", "sine=frequency=440:duration=\(duration):sample_rate=44100",
            "-ac", "1",
            "-b:a", "64k",
            "-f", "mp3",
            url.path
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
            throw FixtureError.ffmpegFailed(message)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FixtureError.missingGeneratedMP3
        }

        return url
    }

    private static var ffmpegExecutableURL: URL? {
        [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case missingFFmpeg
        case ffmpegFailed(String)
        case missingGeneratedMP3

        var description: String {
            switch self {
            case .missingFFmpeg:
                "FFmpeg is required for the opt-in MP3 fixture test but was not found."
            case .ffmpegFailed(let message):
                "FFmpeg failed to generate an MP3 fixture: \(message)"
            case .missingGeneratedMP3:
                "FFmpeg reported success but no MP3 fixture was written."
            }
        }
    }
}
