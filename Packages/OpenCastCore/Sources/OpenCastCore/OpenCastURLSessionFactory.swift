import Foundation

public enum OpenCastURLSessionFactory {
    /// General app identity for feeds, artwork, and API calls. It carries no
    /// URL: some CDN edges (CBC's Akamai) reset connections whose User-Agent
    /// contains one. Set once at app startup (single-threaded launch window)
    /// before any session configuration is built; the static default serves
    /// tests. The media profile's user agent is a separate, byte-stable parity
    /// contract (`OpenCastMediaRequestProfile`) that episode downloads set per
    /// request over this default, and is never derived from this.
    nonisolated(unsafe) public private(set) static var userAgent = generalUserAgent(version: "1.0")

    public static func setMarketingVersion(_ version: String) {
        FeedWorkspace.cleanAbandonedJobs()
        userAgent = generalUserAgent(version: version)
    }

    static func generalUserAgent(version: String) -> String {
        "OpenCast/\(version)"
    }

    public static let memoryCacheCapacity = 32 * 1_024 * 1_024
    public static let diskCacheCapacity = 128 * 1_024 * 1_024
    public static let requestTimeout: TimeInterval = 20
    public static let resourceTimeout: TimeInterval = 60
    public static let downloadRequestTimeout: TimeInterval = 30
    public static let downloadResourceTimeout: TimeInterval = 60 * 60
    public static let streamingRangeResourceTimeout: TimeInterval = 120

    private static let urlCacheLock = NSLock()
    nonisolated(unsafe) private static var urlCachesByDirectory: [String: URLCache] = [:]

    public static func sharedConfiguration(cacheDirectory: URL? = nil) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        configuration.urlCache = sharedURLCache(directory: cacheDirectory)
        return configuration
    }

    /// One `URLCache` per on-disk directory: independent instances over the
    /// same store would keep separate in-memory indexes and eviction
    /// accounting while contending for the same files.
    private static func sharedURLCache(directory: URL?) -> URLCache {
        let key = directory?.standardizedFileURL.path ?? ""
        return urlCacheLock.withLock {
            if let cache = urlCachesByDirectory[key] {
                return cache
            }
            let cache = URLCache(
                memoryCapacity: memoryCacheCapacity,
                diskCapacity: diskCacheCapacity,
                directory: directory
            )
            urlCachesByDirectory[key] = cache
            return cache
        }
    }

    public static func feedConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 300
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        configuration.urlCache = nil
        return configuration
    }

    public static func downloadConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = downloadRequestTimeout
        configuration.timeoutIntervalForResource = downloadResourceTimeout
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        configuration.urlCache = nil
        return configuration
    }

    public static func streamingRangeConfiguration() -> URLSessionConfiguration {
        let configuration = downloadConfiguration()
        configuration.timeoutIntervalForResource = streamingRangeResourceTimeout
        return configuration
    }
}
