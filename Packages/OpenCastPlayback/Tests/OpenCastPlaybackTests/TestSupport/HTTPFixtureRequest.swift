import Foundation

struct HTTPFixtureRequest: Equatable, Sendable {
    enum ByteRange: Equatable, Sendable {
        case bounded(Range<Int64>)
        case openEnded(lowerBound: Int64)
        case suffix(length: Int64)

        func resolved(contentLength: Int) -> Range<Int>? {
            let contentLength = Int64(contentLength)
            switch self {
            case .bounded(let range):
                guard range.lowerBound >= 0,
                      range.upperBound > range.lowerBound,
                      range.lowerBound < contentLength
                else {
                    return nil
                }
                return Int(range.lowerBound)..<Int(min(range.upperBound, contentLength))
            case .openEnded(let lowerBound):
                guard lowerBound >= 0, lowerBound < contentLength else {
                    return nil
                }
                return Int(lowerBound)..<Int(contentLength)
            case .suffix(let length):
                guard length > 0 else {
                    return nil
                }
                let lowerBound = max(contentLength - length, 0)
                return Int(lowerBound)..<Int(contentLength)
            }
        }
    }

    let method: String
    let path: String
    let headers: [String: String]
    let byteRange: ByteRange?

    init(_ rawRequest: String) {
        let lines = rawRequest.components(separatedBy: "\r\n")
        let requestLineParts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        method = requestLineParts.first.map(String.init) ?? ""
        path = requestLineParts.dropFirst().first.map(Self.normalizedPath(from:)) ?? "/"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty else {
                break
            }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }
            let name = String(parts[0]).lowercased()
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        self.headers = headers
        byteRange = Self.parseByteRange(headers["range"])
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    private static func normalizedPath(from target: Substring) -> String {
        let target = String(target)
        if let url = URL(string: target),
           url.scheme?.hasPrefix("http") == true {
            var path = url.path.isEmpty ? "/" : url.path
            if let query = url.query {
                path += "?\(query)"
            }
            return path
        }
        return target.isEmpty ? "/" : target
    }

    private static func parseByteRange(_ value: String?) -> ByteRange? {
        guard let value,
              value.lowercased().hasPrefix("bytes=")
        else {
            return nil
        }

        let byteRange = value.dropFirst("bytes=".count)
        guard !byteRange.contains(",") else {
            return nil
        }

        let parts = byteRange.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }

        if parts[0].isEmpty,
           let suffixLength = Int64(parts[1]),
           suffixLength > 0 {
            return .suffix(length: suffixLength)
        }

        guard let start = Int64(parts[0]) else {
            return nil
        }

        if parts[1].isEmpty {
            return .openEnded(lowerBound: start)
        }

        guard let end = Int64(parts[1]), start <= end else {
            return nil
        }
        return .bounded(start..<(end + 1))
    }
}
