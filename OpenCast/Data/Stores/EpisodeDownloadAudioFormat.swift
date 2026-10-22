import Foundation

/// The audio container a completed download holds. AVFoundation, AVAudioFile
/// and Speech pick a local file's reader from its extension, so a download
/// whose enclosure URL names no audio extension is named after the format
/// its bytes or its response prove.
nonisolated enum EpisodeDownloadAudioFormat: String, Sendable {
    case mp3, aac, m4a, ogg, wav, flac, aiff, caf

    static let knownExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "mp4", "aac", "ogg", "oga", "opus", "wav", "flac", "aif", "aiff", "caf",
    ]

    private static let headerByteCount = 16
    private static let postTagWindowByteCount = 4_096
    private static let maximumLeadingTagCount = 4

    private static let formatsByMIMEType: [String: Self] = [
        "audio/mpeg": .mp3,
        "audio/mp3": .mp3,
        "audio/mp4": .m4a,
        "audio/x-m4a": .m4a,
        "audio/m4a": .m4a,
        "audio/aac": .aac,
        "audio/aacp": .aac,
        "audio/ogg": .ogg,
        "audio/wav": .wav,
        "audio/x-wav": .wav,
        "audio/wave": .wav,
        "audio/flac": .flac,
        "audio/x-flac": .flac,
        "audio/aiff": .aiff,
        "audio/x-aiff": .aiff,
    ]

    var fileExtension: String {
        rawValue
    }

    static func isKnownAudioExtension(_ extensionName: String) -> Bool {
        knownExtensions.contains(extensionName.lowercased())
    }

    /// The format a container or frame header proves. An ID3v2 tag proves
    /// nothing (MP3 and ADTS both carry one), so a tagged file is classified
    /// only by `sniff(fileAt:)`, which steps over the tag.
    static func sniff(_ header: Data) -> Self? {
        let bytes = Array(header.prefix(headerByteCount))
        func hasASCII(_ signature: String, at offset: Int) -> Bool {
            let expected = Array(signature.utf8)
            return bytes.count >= offset + expected.count
                && Array(bytes[offset..<offset + expected.count]) == expected
        }

        if bytes.count >= 2, bytes[0] == 0xFF {
            // ADTS: 12-bit sync and layer 00. MPEG audio: 11-bit sync and a
            // non-reserved layer.
            if bytes[1] & 0xF6 == 0xF0 {
                return .aac
            }
            if bytes[1] & 0xE0 == 0xE0, bytes[1] & 0x06 != 0 {
                return .mp3
            }
        }
        if hasASCII("ftyp", at: 4) {
            return .m4a
        }
        if hasASCII("OggS", at: 0) {
            return .ogg
        }
        if hasASCII("RIFF", at: 0), hasASCII("WAVE", at: 8) {
            return .wav
        }
        if hasASCII("fLaC", at: 0) {
            return .flac
        }
        if hasASCII("FORM", at: 0), hasASCII("AIFF", at: 8) || hasASCII("AIFC", at: 8) {
            return .aiff
        }
        if hasASCII("caff", at: 0) {
            return .caf
        }
        return nil
    }

    static func sniff(fileAt url: URL) -> Self? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        var offset: UInt64 = 0
        for _ in 0...maximumLeadingTagCount {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let window = try? handle.read(
                      upToCount: offset == 0 ? headerByteCount : postTagWindowByteCount
                  )
            else {
                return nil
            }
            if let tagByteCount = id3TagByteCount(window) {
                offset += tagByteCount
                continue
            }
            // Encoders can pad past a tag's declared size with zeros.
            return sniff(offset == 0 ? window : window.drop { $0 == 0 })
        }
        return nil
    }

    /// The whole length of a well-formed ID3v2 tag at the start of `header`:
    /// the 10-byte header, the syncsafe-sized body and a v2.4 footer.
    private static func id3TagByteCount(_ header: Data) -> UInt64? {
        let bytes = Array(header.prefix(10))
        guard bytes.count == 10,
              bytes[0...2].elementsEqual("ID3".utf8),
              (2...4).contains(bytes[3]),
              bytes[4] != 0xFF,
              bytes[6...9].allSatisfy({ $0 < 0x80 })
        else {
            return nil
        }
        let bodyByteCount = bytes[6...9].reduce(UInt64(0)) { $0 << 7 | UInt64($1) }
        let footerByteCount: UInt64 = bytes[3] == 4 && bytes[5] & 0x10 != 0 ? 10 : 0
        return 10 + bodyByteCount + footerByteCount
    }

    static func fromMIMEType(_ mimeType: String?) -> Self? {
        guard let essence = mimeType?.split(separator: ";").first else {
            return nil
        }
        return formatsByMIMEType[essence.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// The lowercased extension of a response's suggested filename when it is
    /// a known audio extension.
    static func fromFilename(_ filename: String?) -> String? {
        guard let filename, let dotIndex = filename.lastIndex(of: ".") else {
            return nil
        }
        let extensionName = filename[filename.index(after: dotIndex)...].lowercased()
        return knownExtensions.contains(extensionName) ? extensionName : nil
    }
}
