import Foundation

/// Bounds XMLParser's input before it can accumulate a giant CDATA/comment or
/// attribute token internally. Foundation still owns XML syntax and encoding.
final class FeedXMLInputStream: InputStream {
    private let source: InputStream
    private var decodedBytes = 0
    private var tokenBytes = 0
    private var recent: UInt64 = 0
    private var mode = Mode.text
    private var quote: UInt8?
    private var failure: (any Error)?
    private let maximumBytes: Int
    private let unitWidth: Int
    private let littleEndian: Bool
    private var unit: UInt32 = 0
    private var unitOffset = 0
    private(set) var incompleteReason: FeedIncompleteReason?
    private enum Mode { case text, markup, cdata, comment }

    init(fileURL: URL, maximumBytes: Int = FeedResourcePolicy.maximumDecodedBytes) throws {
        guard let source = InputStream(url: fileURL) else { throw CocoaError(.fileReadUnknown) }
        let handle = try FileHandle(forReadingFrom: fileURL)
        let prefix = try handle.read(upToCount: 4) ?? Data()
        try handle.close()
        let encoding = RSSFeedRecovery.unicodeEncoding(in: prefix)
        unitWidth = [.utf32LittleEndian, .utf32BigEndian].contains(encoding) ? 4
            : [.utf16LittleEndian, .utf16BigEndian].contains(encoding) ? 2 : 1
        littleEndian = [.utf16LittleEndian, .utf32LittleEndian].contains(encoding)
        self.maximumBytes = maximumBytes
        self.source = source
        super.init(data: Data())
    }

    override func open() { source.open() }
    override func close() { source.close() }
    override var hasBytesAvailable: Bool { failure == nil && source.hasBytesAvailable }
    override var streamStatus: Stream.Status { failure == nil ? source.streamStatus : .error }
    override var streamError: (any Error)? { failure ?? source.streamError }
    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>) -> Bool { false }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        if Task.isCancelled { failure = CancellationError(); return -1 }
        if failure != nil { return -1 }
        let available = maximumBytes - decodedBytes
        let count = source.read(buffer, maxLength: min(len, FeedResourcePolicy.chunkBytes, max(available, 1)))
        guard count > 0 else { return count }
        if count > available { return fail(.decodedByteLimit) }
        decodedBytes += count
        for index in 0..<count {
            let raw = buffer[index]
            let byte: UInt8
            if unitWidth == 1 {
                byte = raw
                tokenBytes += 1
            } else {
                let shift = (littleEndian ? unitOffset : unitWidth - unitOffset - 1) * 8
                unit |= UInt32(raw) << shift
                unitOffset += 1
                if unitOffset < unitWidth { continue }
                byte = unit < 128 ? UInt8(unit) : 0xFF
                // Count a surrogate pair as four UTF-8 bytes, keeping this
                // pre-parser token guard consistent with the text budgets.
                tokenBytes += unit < 0x80 ? 1 : unit < 0x800 ? 2
                    : (0xD800...0xDFFF).contains(unit) ? 2 : unit < 0x10000 ? 3 : 4
                unit = 0
                unitOffset = 0
            }
            recent = (recent << 8) | UInt64(byte)
            if tokenBytes > FeedResourcePolicy.maximumFieldBytes + 1_024 { return fail(.fieldLimit) }
            switch mode {
            case .text where byte == 60:
                mode = .markup
                tokenBytes = 1
            case .markup:
                if recent == 0x215b43444154415b { mode = .cdata }
                else if recent & 0xffffffff == 0x3c212d2d { mode = .comment }
                else if let quote {
                    if byte == quote { self.quote = nil }
                } else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 62 { mode = .text; tokenBytes = 0 }
            case .cdata where recent & 0xffffff == 0x5d5d3e:
                mode = .text
                tokenBytes = 0
            case .comment where recent & 0xffffff == 0x2d2d3e:
                mode = .text
                tokenBytes = 0
            default: break
            }
        }
        return count
    }

    private func fail(_ reason: FeedIncompleteReason) -> Int {
        incompleteReason = reason
        failure = OpenCastCoreError.malformedFeed(reason: reason.diagnostic)
        return -1
    }
}
