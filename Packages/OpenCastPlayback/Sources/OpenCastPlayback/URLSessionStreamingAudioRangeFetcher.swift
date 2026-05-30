import Foundation
import OpenCastCore

nonisolated final class URLSessionStreamingAudioRangeFetcher: StreamingAudioHTTPRangeFetching, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = URLSessionStreamingAudioRangeFetcher.makeSession()) {
        self.session = session
    }

    @concurrent
    func data(for url: URL, range: Range<Int64>) async throws -> StreamingAudioRangeResponse {
        guard range.lowerBound >= 0, range.upperBound > range.lowerBound else {
            throw StreamingAudioCacheError.invalidRange
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StreamingAudioCacheError.unexpectedStatus(-1)
        }
        guard httpResponse.url == nil || httpResponse.url == url else {
            throw StreamingAudioCacheError.redirected
        }
        guard httpResponse.statusCode == 206 else {
            if httpResponse.statusCode == 200 {
                throw StreamingAudioCacheError.noRangeSupport
            }
            throw StreamingAudioCacheError.unexpectedStatus(httpResponse.statusCode)
        }

        let contentRange = try Self.contentRange(from: httpResponse) ?? range
        let normalizedResponse = OpenCastHTTPResponse(httpResponse)
        let metadata = StreamingAudioRangeMetadata(
            contentLength: Self.contentLength(from: httpResponse),
            mimeType: httpResponse.mimeType,
            etag: normalizedResponse.headerValue("etag"),
            lastModified: normalizedResponse.headerValue("last-modified"),
            acceptsRanges: normalizedResponse.headerValue("accept-ranges")?.lowercased() == "bytes",
            responseURL: httpResponse.url
        )
        return StreamingAudioRangeResponse(data: data, range: contentRange, metadata: metadata)
    }

    private nonisolated static func makeSession() -> URLSession {
        URLSession(configuration: OpenCastURLSessionFactory.streamingRangeConfiguration())
    }

    private nonisolated static func contentRange(from response: HTTPURLResponse) throws -> Range<Int64>? {
        guard let value = OpenCastHTTPResponse(response).headerValue("content-range") else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else {
            return nil
        }

        let rangeAndTotal = trimmed.dropFirst("bytes ".count).split(separator: "/", maxSplits: 1)
        guard let byteRange = rangeAndTotal.first else {
            return nil
        }

        let bounds = byteRange.split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let lower = Int64(bounds[0]),
              let upperInclusive = Int64(bounds[1]),
              upperInclusive >= lower
        else {
            throw StreamingAudioCacheError.invalidRange
        }

        return lower..<(upperInclusive + 1)
    }

    private nonisolated static func contentLength(from response: HTTPURLResponse) -> Int64? {
        let response = OpenCastHTTPResponse(response)
        if let contentRange = response.headerValue("content-range"),
           let total = contentRange.split(separator: "/", maxSplits: 1).last,
           total != "*",
           let value = Int64(total) {
            return value
        }

        return response.expectedContentLength >= 0 ? response.expectedContentLength : nil
    }
}
