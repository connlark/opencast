import CryptoKit
import Foundation

public enum OpenCastSHA256 {
    public static func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }
        return hexString(for: hasher.finalize())
    }

    public static func hash(_ data: Data) -> String {
        hexString(for: SHA256.hash(data: data))
    }

    @concurrent
    public static func hashFileOffCaller(at url: URL) async throws -> String {
        try Task.checkCancellation()
        let hash = try hashFile(at: url)
        try Task.checkCancellation()
        return hash
    }

    private static func hexString<Bytes: Sequence>(for bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let alphabet = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        output.reserveCapacity(64)
        for byte in bytes {
            output.append(alphabet[Int(byte >> 4)])
            output.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
