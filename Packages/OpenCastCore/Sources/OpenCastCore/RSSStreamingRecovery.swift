import Foundation

extension RSSFeedRecovery {
    /// Writes UTF-8 with a matching declaration and copies CDATA verbatim.
    static func recoverFile(from source: URL, to destination: URL) throws -> Bool {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let prefix = try input.read(upToCount: 1_024) ?? Data()
        try input.seek(toOffset: 0)
        let encoding = declaredEncoding(in: prefix) ?? .utf8
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var pendingBytes = Data()
        var pendingText = ""
        var inCDATA = false
        var outputBytes = 0
        var isFirstChunk = true

        func write(_ text: String, repair: Bool) throws {
            let value = repair ? recoverEntities(inFragment: text) : text
            let data = Data(value.utf8)
            outputBytes += data.count
            // Entity repair can expand the output, so it has its own bound.
            guard outputBytes <= FeedResourcePolicy.maximumProcessingBytes else {
                throw OpenCastCoreError.malformedFeed(reason: "Entity recovery exceeded its processing budget.")
            }
            try output.write(contentsOf: data)
        }

        while true {
            try Task.checkCancellation()
            // Decoding and entity repair autorelease objects: drain them per chunk, not per pass.
            let finished: Bool? = try autoreleasepool {
                let chunk = try input.read(upToCount: FeedResourcePolicy.chunkBytes) ?? Data()
                let atEnd = chunk.isEmpty
                pendingBytes.append(chunk)
                var decoded: String?
                var usedBytes = pendingBytes.count
                for suffix in 0...min(8, pendingBytes.count) {
                    if atEnd, suffix > 0 { break }
                    usedBytes = pendingBytes.count - suffix
                    if let value = String(data: pendingBytes.prefix(usedBytes), encoding: encoding) {
                        decoded = value
                        break
                    }
                }
                guard var decoded else { return nil }
                if isFirstChunk {
                    if decoded.first == "\u{FEFF}" { decoded.removeFirst() }
                    normalizeEncodingDeclaration(in: &decoded)
                    isFirstChunk = false
                }
                pendingBytes.removeFirst(usedBytes)
                pendingText += decoded
                while !pendingText.isEmpty {
                    let delimiter = inCDATA ? "]]>" : "<![CDATA["
                    if let range = pendingText.range(of: delimiter) {
                        try write(String(pendingText[..<range.lowerBound]), repair: !inCDATA)
                        try write(delimiter, repair: false)
                        pendingText = String(pendingText[range.upperBound...])
                        inCDATA.toggle()
                    } else {
                        var end = atEnd ? pendingText.endIndex : pendingText.index(pendingText.endIndex,
                            offsetBy: -min(256, pendingText.count))
                        if !inCDATA, !atEnd,
                           let amp = pendingText[..<end].lastIndex(of: "&"),
                           pendingText.distance(from: amp, to: end) < 256,
                           !pendingText[amp..<end].contains(";") {
                            end = amp
                        }
                        let fragment = String(pendingText[..<end])
                        try write(fragment, repair: !inCDATA)
                        // libxml caps one CDATA token below the field budget, so long
                        // CDATA is split into adjacent sections that keep every character.
                        if inCDATA, !atEnd, !fragment.isEmpty {
                            try write("]]><![CDATA[", repair: false)
                        }
                        pendingText = String(pendingText[end...])
                        break
                    }
                }
                return atEnd
            }
            guard let finished else { return false }
            if finished { break }
        }
        return true
    }
}
