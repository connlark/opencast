import Foundation

struct HTTPFixtureServerScenario: Equatable, Sendable {
    enum RangeBehavior: Equatable, Sendable {
        case normal
        case none
        case ignored
        case partialWithoutContentRange
        case malformedContentRange(String)
        case rangeNotSatisfiable
        case unknownTotal
        case mismatchedContentRange

        var advertisesRanges: Bool {
            switch self {
            case .none:
                false
            case .normal,
                 .ignored,
                 .partialWithoutContentRange,
                 .malformedContentRange,
                 .rangeNotSatisfiable,
                 .unknownTotal,
                 .mismatchedContentRange:
                true
            }
        }
    }

    enum ValidatorBehavior: Equatable, Sendable {
        case stable(etag: String?, lastModified: String?)
        case missing
        case changing(etags: [String], lastModifieds: [String?])
    }

    enum RedirectBehavior: Equatable, Sendable {
        case none
        case stable(path: String)
        case unstable(prefix: String)
    }

    enum BodyBehavior: Equatable, Sendable {
        case immediate
        case slow(chunkSize: Int, interval: TimeInterval)
        case earlyClose(afterBytes: Int)
        case wrongContentLength(delta: Int)
    }

    let data: Data
    let fileName: String
    let contentType: String
    let rangeBehavior: RangeBehavior
    let validatorBehavior: ValidatorBehavior
    let redirectBehavior: RedirectBehavior
    let bodyBehavior: BodyBehavior

    init(
        data: Data,
        fileName: String,
        contentType: String,
        rangeBehavior: RangeBehavior = .normal,
        validatorBehavior: ValidatorBehavior = .stable(etag: #""opencast-fixture""#, lastModified: nil),
        redirectBehavior: RedirectBehavior = .none,
        bodyBehavior: BodyBehavior = .immediate
    ) {
        self.data = data
        self.fileName = fileName
        self.contentType = contentType
        self.rangeBehavior = rangeBehavior
        self.validatorBehavior = validatorBehavior
        self.redirectBehavior = redirectBehavior
        self.bodyBehavior = bodyBehavior
    }

    static func hlsPlaylist(
        fileName: String = "playlist.m3u8",
        bodyBehavior: BodyBehavior = .immediate
    ) -> HTTPFixtureServerScenario {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXTINF:10,
        segment-0.ts
        #EXT-X-ENDLIST

        """
        return HTTPFixtureServerScenario(
            data: Data(playlist.utf8),
            fileName: fileName,
            contentType: "application/vnd.apple.mpegurl",
            rangeBehavior: .none,
            validatorBehavior: .missing,
            bodyBehavior: bodyBehavior
        )
    }

    var primaryPath: String {
        Self.normalizedPath(fileName)
    }

    func normalizedRedirectPath(_ path: String) -> String {
        Self.normalizedPath(path)
    }

    private static func normalizedPath(_ path: String) -> String {
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return "/\(trimmedPath)"
    }
}
