import Foundation

public enum OpenCastURLSessionFactory {
    /// Set once at app startup (single-threaded launch window) before any
    /// session configuration is built; the static default serves tests. The
    /// media profile's user agent is a separate, byte-stable contract
    /// (`OpenCastMediaRequestProfile`) and is never derived from this.
    nonisolated(unsafe) public private(set) static var userAgent = "OpenCast/1.0 (+https://opencast.mobile)"

    public static func setMarketingVersion(_ version: String) {
        userAgent = "OpenCast/\(version) (+https://opencast.mobile)"
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
