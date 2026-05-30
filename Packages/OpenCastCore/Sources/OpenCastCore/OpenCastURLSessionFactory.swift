import Foundation

public enum OpenCastURLSessionFactory {
    public static let userAgent = "OpenCast/1.0"
    public static let memoryCacheCapacity = 32 * 1_024 * 1_024
    public static let diskCacheCapacity = 128 * 1_024 * 1_024
    public static let requestTimeout: TimeInterval = 20
    public static let resourceTimeout: TimeInterval = 60
    public static let downloadRequestTimeout: TimeInterval = 30
    public static let downloadResourceTimeout: TimeInterval = 60 * 60
    public static let streamingRangeResourceTimeout: TimeInterval = 120

    public static func sharedConfiguration(cacheDirectory: URL? = nil) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        configuration.urlCache = URLCache(
            memoryCapacity: memoryCacheCapacity,
            diskCapacity: diskCacheCapacity,
            directory: cacheDirectory
        )
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
