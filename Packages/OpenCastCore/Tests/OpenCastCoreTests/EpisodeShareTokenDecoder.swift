import Foundation
@testable import OpenCastCore
import zlib

/// Test-only inverse of `EpisodeShareTokenEncoder`. The app never decodes a
/// share token; the worker does. This proves the Swift output round-trips
/// through the same raw-inflate-with-dictionary contract.
enum EpisodeShareTokenDecoder {
    enum Failure: Error {
        case version
        case base64
        case inflate(Int32)
        case utf8
    }

    static func tupleFields(from token: String) throws -> [String] {
        guard token.first == "1" else {
            throw Failure.version
        }
        let bytes = try inflate(base64URLDecoded(String(token.dropFirst())))
        guard let tuple = String(validating: bytes, as: UTF8.self) else {
            throw Failure.utf8
        }
        return tuple.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The same tuple deflated without the preset dictionary, to prove a
    /// vector's `maxTokenLength` would catch an encoder that skipped it.
    static func tokenWithoutDictionary(for payload: EpisodeSharePayload) throws -> String {
        var input = Array(payload.tupleFields.joined(separator: "\n").utf8)
        var stream = z_stream()
        return try withUnsafeMutablePointer(to: &stream) { stream in
            guard deflateInit2_(
                stream, Z_BEST_COMPRESSION, Z_DEFLATED, -15, 9, Z_DEFAULT_STRATEGY,
                ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
            ) == Z_OK else {
                throw Failure.inflate(Z_STREAM_ERROR)
            }
            defer { deflateEnd(stream) }
            var output = [UInt8](repeating: 0, count: Int(deflateBound(stream, uLong(input.count))))
            let produced = try input.withUnsafeMutableBufferPointer { input in
                try output.withUnsafeMutableBufferPointer { output in
                    stream.pointee.next_in = input.baseAddress
                    stream.pointee.avail_in = uInt(input.count)
                    stream.pointee.next_out = output.baseAddress
                    stream.pointee.avail_out = uInt(output.count)
                    let status = deflate(stream, Z_FINISH)
                    guard status == Z_STREAM_END else {
                        throw Failure.inflate(status)
                    }
                    return output.count - Int(stream.pointee.avail_out)
                }
            }
            return "1" + EpisodeShareTokenEncoder.base64URL(Array(output.prefix(produced)))
        }
    }

    private static func base64URLDecoded(_ value: String) throws -> [UInt8] {
        var base64 = value.replacing("-", with: "+").replacing("_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else {
            throw Failure.base64
        }
        return Array(data)
    }

    private static func inflate(_ bytes: [UInt8]) throws -> [UInt8] {
        var input = bytes
        var stream = z_stream()
        return try withUnsafeMutablePointer(to: &stream) { stream in
            guard inflateInit2_(stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw Failure.inflate(Z_STREAM_ERROR)
            }
            defer { inflateEnd(stream) }
            // A raw stream never reports Z_NEED_DICT, so install the dictionary first.
            let dictionaryStatus = EpisodeShareDictionary.v1.withUnsafeBufferPointer { dictionary in
                inflateSetDictionary(stream, dictionary.baseAddress, uInt(dictionary.count))
            }
            guard dictionaryStatus == Z_OK else {
                throw Failure.inflate(dictionaryStatus)
            }
            var output = [UInt8](repeating: 0, count: 16_384)
            let produced = try input.withUnsafeMutableBufferPointer { input in
                try output.withUnsafeMutableBufferPointer { output in
                    stream.pointee.next_in = input.baseAddress
                    stream.pointee.avail_in = uInt(input.count)
                    stream.pointee.next_out = output.baseAddress
                    stream.pointee.avail_out = uInt(output.count)
                    let status = zlib.inflate(stream, Z_FINISH)
                    guard status == Z_STREAM_END else {
                        throw Failure.inflate(status)
                    }
                    return output.count - Int(stream.pointee.avail_out)
                }
            }
            return Array(output.prefix(produced))
        }
    }
}
