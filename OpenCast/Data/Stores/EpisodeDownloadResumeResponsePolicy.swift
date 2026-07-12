import Foundation

nonisolated enum EpisodeDownloadResumeResponsePolicy: Equatable, Sendable {
    case append(bytesExpected: Int64?)
    case restart(bytesExpected: Int64?, requiresNewRequest: Bool)
    case fail(statusCode: Int)

    nonisolated static func evaluate(
        statusCode: Int,
        resumeOffset: Int64,
        headers: [String: String]
    ) -> Self {
        switch statusCode {
        case 200:
            return .restart(
                bytesExpected: contentLength(in: headers),
                requiresNewRequest: false
            )
        case 206:
            guard let contentRange = contentRange(in: headers),
                  contentRange.start == resumeOffset,
                  let total = contentRange.total
            else {
                return resumeOffset > 0
                    ? .restart(bytesExpected: nil, requiresNewRequest: true)
                    : .fail(statusCode: statusCode)
            }
            guard resumeOffset > 0 else {
                return .restart(
                    bytesExpected: total,
                    requiresNewRequest: false
                )
            }
            return .append(bytesExpected: total)
        case 416 where resumeOffset > 0:
            return .restart(bytesExpected: nil, requiresNewRequest: true)
        default:
            return .fail(statusCode: statusCode)
        }
    }

    private nonisolated static func contentLength(in headers: [String: String]) -> Int64? {
        guard let value = header(named: "Content-Length", in: headers),
              let length = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              length >= 0
        else {
            return nil
        }
        return length
    }

    private nonisolated static func contentRange(
        in headers: [String: String]
    ) -> (start: Int64, total: Int64?)? {
        guard let value = header(named: "Content-Range", in: headers) else {
            return nil
        }

        let components = value.split(whereSeparator: { $0.isWhitespace })
        guard components.count == 2,
              String(components[0]).caseInsensitiveCompare("bytes") == .orderedSame
        else {
            return nil
        }

        let rangeAndTotal = components[1].split(separator: "/", maxSplits: 1)
        guard rangeAndTotal.count == 2 else {
            return nil
        }

        let byteRange = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
        guard byteRange.count == 2,
              let start = Int64(byteRange[0]),
              let end = Int64(byteRange[1]),
              start >= 0,
              end >= start
        else {
            return nil
        }

        let total: Int64?
        if rangeAndTotal[1] == "*" {
            total = nil
        } else {
            guard let parsedTotal = Int64(rangeAndTotal[1]), parsedTotal > end else {
                return nil
            }
            total = parsedTotal
        }
        return (start, total)
    }

    private nonisolated static func header(
        named name: String,
        in headers: [String: String]
    ) -> String? {
        headers.first { key, _ in
            key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}
