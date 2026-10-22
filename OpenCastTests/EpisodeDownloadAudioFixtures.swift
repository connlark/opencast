import Foundation

/// Byte layouts the download format sniff must classify, shared by the
/// infrastructure and store suites.
nonisolated enum EpisodeDownloadAudioFixtures {
    static let mpegFrameHeader: [UInt8] = [0xFF, 0xFB, 0x90, 0x64]
    static let adtsFrameHeader: [UInt8] = [0xFF, 0xF1, 0x50, 0x80]

    static let taggedMP3 = id3Tagged(mpegFrameHeader) + Data("mp3 frames".utf8)

    /// An ID3v2.4 tag whose syncsafe size declares `bodyByteCount` bytes,
    /// followed by `trailingPadding` zero bytes the size does not count, then
    /// `frame`.
    static func id3Tagged(_ frame: [UInt8], bodyByteCount: Int = 64, trailingPadding: Int = 0) -> Data {
        let syncsafeSize = [21, 14, 7, 0].map { UInt8((bodyByteCount >> $0) & 0x7F) }
        let header = Array("ID3".utf8) + [0x04, 0x00, 0x00] + syncsafeSize
        let body = Array(repeating: UInt8(0x00), count: bodyByteCount + trailingPadding)
        return Data(header + body + frame)
    }
}
