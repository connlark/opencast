import Foundation

extension RSSFeedRecovery {
    /// Decode bounded chunks, retaining an incomplete code point and delimiter
    /// suffix between reads. CDATA is copied verbatim; entity repair only runs
    /// outside it. Recovery writes UTF-8 with a matching declaration.
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
            // Recovery may expand ampersands. Its output still has a bounded
            // processing envelope and never changes the source-byte policy.
            guard outputBytes <= FeedResourcePolicy.maximumProcessingBytes else {
                throw OpenCastCoreError.malformedFeed(reason: "Entity recovery exceeded its processing budget.")
            }
            try output.write(contentsOf: data)
        }

        while true {
            try Task.checkCancellation()
            // Foundation decoding and entity repair create autoreleased
            // objects even though the Swift buffers are bounded. Drain them
            // per chunk instead of retaining an entire recovery pass's text.
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
                        // libxml has its own single-CDATA token ceiling below our
                        // field budget. Adjacent CDATA sections preserve every
                        // character while delivering bounded parser callbacks.
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
