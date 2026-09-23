import Foundation
import zlib

/// Mints the version `1` share token: the payload tuple joined with `\n`, raw
/// DEFLATE (level 9, windowBits −15, memLevel 9) primed with
/// `EpisodeShareDictionary.v1`, then base64url without padding behind a `1`.
/// System zlib rather than `Compression`, which cannot install a preset
/// dictionary. Deflating a 1–2 KB tuple takes tens of microseconds.
public enum EpisodeShareTokenEncoder {
    public enum Error: Swift.Error, Equatable {
        case deflateInit
        case setDictionary
        case deflate
        case tokenTooLong
    }

    public static let maximumTokenLength = 4096
    /// The worker inflates into at most 16 KiB; a repetitive tuple can deflate
    /// far below the token cap and still exceed that.
    public static let maximumTupleBytes = 16_384
    static let version = "1"

    public static func token(for payload: EpisodeSharePayload) throws -> String {
        let tuple = Array(payload.tupleFields.joined(separator: "\n").utf8)
        guard tuple.count <= maximumTupleBytes else {
            throw Error.tokenTooLong
        }
        let token = version + base64URL(try rawDeflate(tuple))
        guard token.utf8.count <= maximumTokenLength else {
            throw Error.tokenTooLong
        }
        return token
    }

    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacing("+", with: "-")
            .replacing("/", with: "_")
            .replacing("=", with: "")
    }

    private static func rawDeflate(_ bytes: [UInt8]) throws -> [UInt8] {
        var input = bytes
        var stream = z_stream()
        // zlib keeps a back-pointer to the stream and rejects calls made with a
        // different address, so every call goes through one pinned pointer.
        return try withUnsafeMutablePointer(to: &stream) { stream in
            guard deflateInit2_(
                stream,
                Z_BEST_COMPRESSION,
                Z_DEFLATED,
                -15,
                9,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            ) == Z_OK else {
                throw Error.deflateInit
            }
            defer { deflateEnd(stream) }

            let dictionaryStatus = EpisodeShareDictionary.v1.withUnsafeBufferPointer { dictionary in
                deflateSetDictionary(stream, dictionary.baseAddress, uInt(dictionary.count))
            }
            guard dictionaryStatus == Z_OK else {
                throw Error.setDictionary
            }

            // A single Z_FINISH call into a deflateBound-sized buffer is
            // guaranteed to return Z_STREAM_END, so anything else is an error.
            var output = [UInt8](repeating: 0, count: Int(deflateBound(stream, uLong(input.count))))
            let produced = try input.withUnsafeMutableBufferPointer { input in
                try output.withUnsafeMutableBufferPointer { output in
                    stream.pointee.next_in = input.baseAddress
                    stream.pointee.avail_in = uInt(input.count)
                    stream.pointee.next_out = output.baseAddress
                    stream.pointee.avail_out = uInt(output.count)
                    guard deflate(stream, Z_FINISH) == Z_STREAM_END else {
                        throw Error.deflate
                    }
                    return output.count - Int(stream.pointee.avail_out)
                }
            }
            return Array(output.prefix(produced))
        }
    }
}
